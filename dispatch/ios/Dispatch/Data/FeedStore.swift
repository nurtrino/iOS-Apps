import Foundation

/// Everything a load needs that is not the source itself.
struct LoadEnvironment {
    var bridge: XBridge
    var steam: SteamContext
    var itemsPerSource: Int
    /// How old a cached feed may be before a non-forced refresh refetches it.
    var staleAfter: TimeInterval
}

/// The articles, per source, where each one was filed, and where each source is
/// in its load cycle.
///
/// Per source rather than per topic for one reason: a topic is fed by several
/// sources, and they fail independently. Storing a topic's articles as one blob
/// means a single dead feed either blanks the screen or is invisible; a
/// per-source phase lets War show The War Zone's articles while saying, quietly,
/// that Telegram did not answer.
@MainActor
final class FeedStore: ObservableObject {

    @Published private(set) var articlesBySource: [String: [Article]] = [:]
    @Published private(set) var phaseBySource: [String: LoadPhase] = [:]
    @Published private(set) var noteBySource: [String: String] = [:]
    @Published private(set) var fetchedBySource: [String: Date] = [:]

    /// Where the classifier put each article, keyed by article id.
    ///
    /// Computed once when articles arrive rather than in the view: a body
    /// evaluation that re-scored every visible row would re-run the lexicon
    /// dozens of times per scroll frame.
    @Published private(set) var verdicts: [String: TopicVerdict] = [:]

    /// Guards against the same source being fetched twice at once, which
    /// happens the moment someone pulls to refresh while the on-appear load is
    /// still running.
    private var inFlight: Set<String> = []

    // MARK: - Cache

    /// Puts the last good copy of every feed on screen before any request goes
    /// out, so a cold launch shows news rather than a screen of spinners.
    func hydrateFromCache(sources: [Source]) {
        for source in sources where articlesBySource[source.id] == nil {
            guard let cache = FeedCache.load(sourceID: source.id) else { continue }
            articlesBySource[source.id] = cache.articles
            fetchedBySource[source.id] = cache.fetched
            noteBySource[source.id] = cache.note
            phaseBySource[source.id] = .loaded
            classify(cache.articles, source: source)
        }
    }

    // MARK: - Loading

    func isStale(_ sourceID: String, staleAfter: TimeInterval) -> Bool {
        guard let fetched = fetchedBySource[sourceID] else { return true }
        return Date().timeIntervalSince(fetched) >= staleAfter
    }

    /// Refreshes a set of sources concurrently.
    ///
    /// `force` is what pull-to-refresh passes: it ignores the staleness window,
    /// because someone who just pulled the list down is asking a question the
    /// cache cannot answer.
    func refresh(sources: [Source], environment: LoadEnvironment, force: Bool) async {
        let due = sources.filter { source in
            guard !inFlight.contains(source.id) else { return false }
            return force || isStale(source.id, staleAfter: environment.staleAfter)
        }
        guard !due.isEmpty else { return }

        for source in due {
            inFlight.insert(source.id)
            let hasContent = !(articlesBySource[source.id]?.isEmpty ?? true)
            phaseBySource[source.id] = hasContent ? .refreshing : .loading
        }

        await withTaskGroup(of: (Source, Result<SourceLoadResult, Error>).self) { group in
            for source in due {
                group.addTask {
                    do {
                        let result = try await SourceLoader.load(
                            source,
                            bridge: environment.bridge,
                            steam: environment.steam,
                            limit: environment.itemsPerSource
                        )
                        return (source, .success(result))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }

            // The body of `withTaskGroup` keeps this actor's isolation, so
            // results are applied on the main actor as each one lands rather
            // than all at once at the end. Topics fill in progressively.
            for await (source, result) in group {
                apply(result, source: source)
            }
        }
    }

    private func apply(_ result: Result<SourceLoadResult, Error>, source: Source) {
        inFlight.remove(source.id)

        switch result {
        case .success(let loaded):
            articlesBySource[source.id] = loaded.articles
            noteBySource[source.id] = loaded.note
            let now = Date()
            fetchedBySource[source.id] = now
            phaseBySource[source.id] = .loaded
            classify(loaded.articles, source: source)
            FeedCache(articles: loaded.articles, fetched: now, note: loaded.note)
                .save(sourceID: source.id)

        case .failure(let error):
            let message = (error as? FeedError)?.errorDescription
                ?? FeedError.from(error).errorDescription
                ?? "Could not load this source."
            phaseBySource[source.id] = .failed(message)
            // Deliberately leaves `articlesBySource` alone: a failed refresh
            // keeps whatever was already on screen.
        }
    }

    private func classify(_ articles: [Article], source: Source) {
        for article in articles {
            verdicts[article.id] = article.classified(using: source)
        }
    }

    /// Re-files everything already loaded.
    ///
    /// Needed when a source's topic settings change: the articles are still
    /// good, but the answer to "which screen does this belong on" is not.
    func reclassify(sources: [Source]) {
        var updated: [String: TopicVerdict] = [:]
        for source in sources {
            for article in articlesBySource[source.id] ?? [] {
                updated[article.id] = article.classified(using: source)
            }
        }
        verdicts = updated
    }

    func clearAll() {
        articlesBySource = [:]
        phaseBySource = [:]
        noteBySource = [:]
        fetchedBySource = [:]
        verdicts = [:]
        DiskStore.clearFeedCaches()
    }

    func forget(sourceID: String) {
        for article in articlesBySource[sourceID] ?? [] { verdicts[article.id] = nil }
        articlesBySource[sourceID] = nil
        phaseBySource[sourceID] = nil
        noteBySource[sourceID] = nil
        fetchedBySource[sourceID] = nil
        FeedCache.delete(sourceID: sourceID)
    }

    // MARK: - Reading

    func articles(for sourceID: String) -> [Article] {
        articlesBySource[sourceID] ?? []
    }

    func verdict(for article: Article) -> TopicVerdict? {
        verdicts[article.id]
    }

    /// One topic's articles: every source that reaches it, filtered to the ones
    /// the classifier actually filed there, merged and newest first.
    func articles(for topic: Topic, from sources: [Source]) -> [Article] {
        var seen = Set<String>()
        var merged: [Article] = []

        for source in sources {
            for article in articlesBySource[source.id] ?? [] {
                guard verdicts[article.id]?.topic == topic else { continue }
                // Source order decides which copy of a cross-posted story wins,
                // and source order is the user's to set.
                guard seen.insert(article.dedupeKey).inserted else { continue }
                merged.append(article)
            }
        }
        return merged.sorted { left, right in
            if left.sortDate != right.sortDate { return left.sortDate > right.sortDate }
            return left.id < right.id
        }
    }

    /// A topic is busy while any of its sources is.
    func phase(for sources: [Source]) -> LoadPhase {
        let phases = sources.compactMap { phaseBySource[$0.id] }
        guard !phases.isEmpty else { return .idle }

        if phases.contains(where: { $0 == .loading }) { return .loading }
        if phases.contains(where: { $0 == .refreshing }) { return .refreshing }
        if phases.contains(where: { $0 == .loaded }) { return .loaded }

        // Everything failed. One source's message is more useful than "3
        // sources failed", so the first one is passed through.
        if let message = phases.compactMap(\.errorMessage).first { return .failed(message) }
        return .idle
    }

    /// Problems worth mentioning without taking the screen over: the sources
    /// that failed while others succeeded, and the ones served from a fallback.
    func advisories(for sources: [Source]) -> [String] {
        var lines: [String] = []
        for source in sources {
            if let message = phaseBySource[source.id]?.errorMessage {
                lines.append("\(source.name): \(message)")
            } else if let note = noteBySource[source.id] {
                lines.append("\(source.name): \(note)")
            }
        }
        return lines
    }

    var everyArticle: [Article] {
        articlesBySource.values.flatMap { $0 }
    }
}
