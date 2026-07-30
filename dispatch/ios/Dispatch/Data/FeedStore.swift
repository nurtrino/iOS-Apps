import Foundation

/// Everything a load needs that is not the source itself.
struct LoadEnvironment {
    var bridge: XBridge
    var steam: SteamContext
    var itemsPerSource: Int
    /// How old a cached feed may be before a non-forced refresh refetches it.
    var staleAfter: TimeInterval
    /// Whether Claude files stories that come from a general outlet.
    var sortsWithModel: Bool = false
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

    /// What the model decided, by article id, kept forever.
    ///
    /// Persisted for one reason: money. A decision costs a fraction of a cent
    /// once and nothing ever after, and a relaunch that re-filed every cached
    /// article would pay again for answers it already had.
    private var modelDecisions: [String: String] = [:]

    /// True while a filing pass is out, so a second refresh does not start one.
    @Published private(set) var isSorting = false

    private static let decisionsFile = "model-verdicts"

    /// A stored decision, and the prompt that produced it.
    ///
    /// Versioned because a decision is an *opinion*, and an opinion held under a
    /// different prompt is not evidence for the current one. The specific harm:
    /// a run that answered "none" too freely wrote those answers to disk, where
    /// they went on hiding stories after the code that produced them was fixed —
    /// caching is what makes the feature cheap and it is also what makes a bad
    /// answer permanent.
    private struct StoredDecisions: Codable {
        var revision: Int
        var decisions: [String: String]
    }

    /// Guards against the same source being fetched twice at once, which
    /// happens the moment someone pulls to refresh while the on-appear load is
    /// still running.
    private var inFlight: Set<String> = []

    init() {
        if let stored = DiskStore.load(StoredDecisions.self, from: FeedStore.decisionsFile) {
            modelDecisions = stored.decisions
            if stored.revision != ClassifierAPI.promptRevision {
                // Only the hiding is discarded. A section is a section whatever
                // prompt produced it, and those answers were paid for; "none" is
                // the one that costs a story if it was wrong.
                modelDecisions = modelDecisions.filter { $0.value != "none" }
            }
        } else if let legacy = DiskStore.load([String: String].self, from: FeedStore.decisionsFile) {
            // Written before decisions were versioned — which is exactly the run
            // whose answers are in question, so none of its hiding survives.
            modelDecisions = legacy.filter { $0.value != "none" }
        }
    }

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

        if environment.sortsWithModel {
            await fileWithModel(sources: sources)
        }
    }

    // MARK: - Filing with the model

    /// Asks Claude where the stories from general outlets belong.
    ///
    /// Runs after the fetch rather than inside it, so the list is on screen with
    /// the lexicon's placement while this is in flight and rows move when the
    /// answers land. Only articles with no stored decision are sent, so the
    /// steady state is a handful of new headlines per refresh and most refreshes
    /// send nothing at all.
    ///
    /// Every failure is silent and non-destructive. A dead network, a bad key or
    /// a rate limit leaves the lexicon's verdicts exactly as they were — which is
    /// a complete, working app — and the next refresh tries again.
    func fileWithModel(sources: [Source]) async {
        guard !isSorting else { return }

        // Fixed-topic sources are not guesses and never need asking about.
        let classified = sources.filter { $0.topicMode == .classified }
        guard !classified.isEmpty else { return }

        var pending: [(id: String, title: String, source: Source)] = []
        for source in classified {
            for article in articlesBySource[source.id] ?? [] where modelDecisions[article.id] == nil {
                pending.append((article.id, article.displayTitle, source))
            }
        }
        guard !pending.isEmpty else { return }
        guard let key = await AnthropicKeychain.shared.load() else { return }

        isSorting = true
        defer { isSorting = false }

        var index = 0
        while index < pending.count {
            let batch = Array(pending[index..<min(index + ClassifierAPI.batchSize, pending.count)])
            index += ClassifierAPI.batchSize

            do {
                let decisions = try await ClassifierAPI.classify(titles: batch.map(\.title), key: key)

                // A sanity check on the answer as a whole. "Belongs nowhere" is a
                // rare verdict on a news wire, so a batch that comes back mostly
                // "none" is far more likely to be a bad reply than forty
                // genuinely off-topic headlines — and acting on it hides most of
                // a source at once, which is exactly the failure this feature was
                // added to end. The sections in such a batch are still used; only
                // the hiding is refused.
                let unplaced = decisions.values.filter { $0 == .unplaced }.count
                let distrusted = unplaced * 2 > batch.count

                for (offset, decision) in decisions {
                    if distrusted, decision == .unplaced { continue }
                    guard batch.indices.contains(offset) else { continue }
                    let entry = batch[offset]
                    let stored: String
                    switch decision {
                    case .section(let topic): stored = topic.rawValue
                    case .unplaced: stored = "none"
                    }
                    modelDecisions[entry.id] = stored
                    if let existing = verdicts[entry.id] {
                        verdicts[entry.id] = FeedStore.applied(stored, to: existing, source: entry.source)
                    }
                }
            } catch {
                // One failed batch ends the pass. Whatever landed before it is
                // kept; the rest are still unfiled and will be asked again.
                break
            }
        }

        saveDecisions()
    }

    /// Written back pruned to the articles still held, so the file cannot grow
    /// without bound as a wire churns through thousands of headlines.
    private func saveDecisions() {
        var live = Set<String>()
        for articles in articlesBySource.values {
            for article in articles { live.insert(article.id) }
        }
        modelDecisions = modelDecisions.filter { live.contains($0.key) }
        DiskStore.save(StoredDecisions(revision: ClassifierAPI.promptRevision,
                                       decisions: modelDecisions),
                       to: FeedStore.decisionsFile)
    }

    /// How many stories are still waiting on the model, for the Sources screen.
    func unfiledCount(sources: [Source]) -> Int {
        var count = 0
        for source in sources where source.topicMode == .classified {
            for article in articlesBySource[source.id] ?? [] where modelDecisions[article.id] == nil {
                count += 1
            }
        }
        return count
    }

    private func apply(_ result: Result<SourceLoadResult, Error>, source: Source) {
        inFlight.remove(source.id)

        switch result {
        case .success(let loaded):
            let merged = FeedStore.merge(incoming: loaded.articles,
                                         existing: articlesBySource[source.id] ?? [])
            articlesBySource[source.id] = merged
            noteBySource[source.id] = loaded.note
            let now = Date()
            fetchedBySource[source.id] = now
            phaseBySource[source.id] = .loaded
            classify(merged, source: source)
            FeedCache(articles: merged, fetched: now, note: loaded.note)
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

    /// How many articles a single source keeps once its feed has moved on.
    ///
    /// Three times a default fetch. Enough that a source posting thirty times a
    /// day holds several days, small enough that ten sources is a few megabytes.
    static let retained = 120

    /// Folds a fresh fetch into what is already held, newest first.
    ///
    /// **This is what stops a fast source losing stories.** A feed is a window,
    /// not an archive: Citizen Free Press publishes dozens of items a day and
    /// its RSS holds a fraction of them, so replacing the list on every fetch
    /// meant anything that entered and left that window between two refreshes
    /// was never seen at all — and anything already read scrolled out of the app
    /// the moment it scrolled out of the feed. Merging turns each fetch into an
    /// addition, and the app accumulates the history the feed does not keep.
    ///
    /// The incoming copy wins on an id collision, because a re-fetch is where a
    /// corrected title or a resolved outbound link arrives. The cost is that a
    /// post deleted upstream lingers until it ages past `retained`, which is the
    /// right way round: silently dropping stories is worse than briefly keeping
    /// one too many.
    static func merge(incoming: [Article], existing: [Article]) -> [Article] {
        guard !existing.isEmpty else { return incoming }

        var byID: [String: Article] = [:]
        var order: [String] = []
        for article in incoming + existing where byID[article.id] == nil {
            byID[article.id] = article
            order.append(article.id)
        }

        let all = order.compactMap { byID[$0] }
        let sorted = all.sorted { left, right in
            if left.sortDate != right.sortDate { return left.sortDate > right.sortDate }
            return left.id < right.id
        }
        return Array(sorted.prefix(retained))
    }

    private func classify(_ articles: [Article], source: Source) {
        for article in articles {
            verdicts[article.id] = verdict(for: article, source: source)
        }
    }

    /// The lexicon's answer, or the model's where it has already given one.
    ///
    /// Checked in this order so a relaunch shows what the model decided rather
    /// than showing the lexicon's guess and visibly flipping a second later.
    private func verdict(for article: Article, source: Source) -> TopicVerdict {
        let lexicon = article.classified(using: source)
        guard let stored = modelDecisions[article.id] else { return lexicon }
        return FeedStore.applied(stored, to: lexicon, source: source)
    }

    /// Folds a stored decision onto the lexicon's verdict.
    ///
    /// "none" only hides a story where the source asked for that. Everywhere
    /// else it leaves the lexicon's placement alone: an outlet whose default is
    /// a fair guess would rather be filed by guess than not appear.
    static func applied(_ decision: String, to lexicon: TopicVerdict, source: Source) -> TopicVerdict {
        if decision == "none" {
            guard source.dropsUnsortable else { return lexicon }
            return TopicVerdict(topic: nil, confidence: 1, evidence: [],
                                isFallback: false, decidedByModel: true)
        }
        guard let topic = Topic(rawValue: decision) else { return lexicon }
        return TopicVerdict(topic: topic, confidence: 1, evidence: [],
                            isFallback: false, decidedByModel: true)
    }

    /// Re-files everything already loaded.
    ///
    /// Needed when a source's topic settings change: the articles are still
    /// good, but the answer to "which screen does this belong on" is not.
    func reclassify(sources: [Source]) {
        var updated: [String: TopicVerdict] = [:]
        for source in sources {
            for article in articlesBySource[source.id] ?? [] {
                updated[article.id] = verdict(for: article, source: source)
            }
        }
        verdicts = updated
    }

    func clearAll() {
        modelDecisions = [:]
        DiskStore.delete(FeedStore.decisionsFile)
        articlesBySource = [:]
        phaseBySource = [:]
        noteBySource = [:]
        fetchedBySource = [:]
        verdicts = [:]
        DiskStore.clearFeedCaches()
    }

    func forget(sourceID: String) {
        for article in articlesBySource[sourceID] ?? [] {
            verdicts[article.id] = nil
            modelDecisions[article.id] = nil
        }
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
        // Which source claimed each key, not merely whether one did.
        //
        // Deduplication exists to fold *one story carried by two outlets* into
        // one row. Two posts from the same outlet are two posts, and collapsing
        // them was a way to lose most of a wire silently: an aggregator's link is
        // rewritten to the article it points at, so anything that made two of its
        // items resolve to the same address — a site-wide link in the template, a
        // pair of posts about the same piece — deleted all but the first from
        // every section, while the source's own screen still listed them.
        var claimedBy: [String: String] = [:]
        var merged: [Article] = []

        for source in sources {
            for article in articlesBySource[source.id] ?? [] {
                // Written out rather than `verdicts[id]?.topic == topic`: the
                // verdict's topic is itself optional now, and the double
                // optional that expression produces does not mean what it looks
                // like it means.
                guard let verdict = verdicts[article.id], verdict.topic == topic else { continue }
                // Source order decides which copy of a cross-posted story wins,
                // and source order is the user's to set.
                if let owner = claimedBy[article.dedupeKey], owner != source.id { continue }
                claimedBy[article.dedupeKey] = source.id
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

            // Hidden stories are never silent. A source that skips what fits
            // nowhere can hide a lot of itself if the filing goes wrong, and the
            // only symptom is a section that looks quiet — so the count says so.
            let hidden = (articlesBySource[source.id] ?? [])
                .filter { verdicts[$0.id]?.topic == nil }
                .count
            if hidden > 0 {
                lines.append("\(source.name): \(hidden) filed in no section — see the source's "
                             + "own screen")
            }
        }
        return lines
    }

    var everyArticle: [Article] {
        articlesBySource.values.flatMap { $0 }
    }
}
