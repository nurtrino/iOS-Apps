import Foundation

/// The merged feed.
@MainActor
final class NewsStore: ObservableObject {

    enum Phase {
        case idle
        case loading
        case loaded
        /// Every enabled source failed. Anything less keeps showing the feed.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var articles: [Article] = []
    /// Source name to what went wrong, for the advisory line above the list.
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var lastRefreshed: Date?

    private var isRefreshing = false

    func refreshIfStale(enabled: Set<String>) async {
        if let last = lastRefreshed, Date().timeIntervalSince(last) < 120,
           !articles.isEmpty {
            return
        }
        await refresh(enabled: enabled)
    }

    func refresh(enabled: Set<String>) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sources = FeedCatalog.sources.filter { enabled.contains($0.id) }
        guard !sources.isEmpty else {
            articles = []
            failures = [:]
            phase = .failed("No sources enabled. Turn some on in Settings.")
            return
        }

        if articles.isEmpty { phase = .loading }

        var collected: [Article] = []
        var problems: [String: String] = [:]

        await withTaskGroup(of: (String, Result<[Article], Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source.name, .success(try await FeedAPI.fetch(source)))
                    } catch {
                        return (source.name, .failure(error))
                    }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let articles):
                    collected += articles
                case .failure(let error):
                    problems[name] = error.localizedDescription
                }
            }
        }

        failures = problems

        if collected.isEmpty {
            let detail = problems.first.map { "\($0.key): \($0.value)" } ?? "No source answered."
            if articles.isEmpty {
                phase = .failed(detail)
            }
            return
        }

        var seen = Set<String>()
        var merged: [Article] = []
        for article in collected.sorted(by: { $0.sortDate > $1.sortDate })
        where seen.insert(article.id).inserted {
            merged.append(article)
        }

        articles = Array(merged.prefix(500))
        lastRefreshed = Date()
        phase = .loaded

        // Everything on screen counts as seen: the background refresh should
        // only ever notify about stories that arrived after the user last
        // looked, not re-announce this list.
        SeenStore.merge(articles.map { $0.id })
    }
}
