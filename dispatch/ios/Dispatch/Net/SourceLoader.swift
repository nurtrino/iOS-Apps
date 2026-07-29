import Foundation

/// What one source produced, and anything the UI should say about how.
struct SourceLoadResult {
    var articles: [Article]
    /// Set when the source worked, but not the way it was configured to —
    /// an X source served from RSS, a feed served from its backup address.
    /// Shown as a quiet line under the section header rather than an error,
    /// because the content did arrive.
    var note: String?
}

/// Everything a Steam source needs that does not live on the source itself.
struct SteamContext {
    var games: [SteamGame]
    var itemsPerGame: Int
    var maxGames: Int

    static let empty = SteamContext(games: [], itemsPerGame: 3, maxGames: 12)
}

/// Turns a `Source` into articles, whatever kind it is.
///
/// The fallback chain is the point of this file. Every source gets a list of
/// candidate addresses, tried in order until one yields items, and only the
/// last failure surfaces. In practice that is what keeps the app usable: news
/// hosts move feed paths, put Cloudflare in front of them, and go down, and a
/// reader that gives up on the first 403 is a reader that is empty on a
/// regular basis.
enum SourceLoader {

    static func load(_ source: Source,
                     bridge: XBridge,
                     steam: SteamContext,
                     limit: Int) async throws -> SourceLoadResult {
        switch source.kind {
        case .rss:
            return try await loadFeeds(for: source, limit: limit)
        case .x:
            return try await loadX(source, bridge: bridge, limit: limit)
        case .telegram:
            return try await loadTelegram(source, limit: limit)
        case .steam:
            return try await loadSteam(source, steam: steam, limit: limit)
        }
    }

    // MARK: - RSS

    private static func loadFeeds(for source: Source, limit: Int) async throws -> SourceLoadResult {
        let candidates = ([source.endpoint] + source.fallbackFeeds).filter { !$0.isEmpty }
        guard !candidates.isEmpty else { throw FeedError.badURL(source.endpoint) }

        var lastError: Error = FeedError.badURL(source.endpoint)
        for (index, candidate) in candidates.enumerated() {
            guard let url = URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme != nil else {
                lastError = FeedError.badURL(candidate)
                continue
            }
            do {
                let articles = try await fetchFeed(url, sourceID: source.id, limit: limit)
                let note = index == 0 ? nil : "Primary feed unreachable — showing \(url.host ?? candidate)."
                return SourceLoadResult(articles: articles, note: note)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchFeed(_ url: URL,
                                  sourceID: String,
                                  limit: Int,
                                  context: String? = nil) async throws -> [Article] {
        let data = try await HTTP.shared.feedData(from: url)
        let feed = try FeedParser.parse(data)
        return feed.items.prefix(limit).map {
            $0.article(sourceID: sourceID, siteLink: feed.siteLink, context: context)
        }
    }

    // MARK: - X

    private static func loadX(_ source: Source,
                              bridge: XBridge,
                              limit: Int) async throws -> SourceLoadResult {
        let handle = XBridge.normalizeHandle(source.endpoint)

        if bridge.isConfigured, let bridged = bridge.feedURL(handle: source.endpoint) {
            do {
                let articles = try await fetchFeed(bridged, sourceID: source.id,
                                                   limit: limit, context: "@\(handle)")
                if !articles.isEmpty { return SourceLoadResult(articles: articles, note: nil) }
            } catch {
                // Bridges fall over often enough that this is expected rather
                // than exceptional. Fall through to the publisher's own feed.
            }
        }

        let fallbacks = source.fallbackFeeds.filter { !$0.isEmpty }
        guard !fallbacks.isEmpty else { throw FeedError.needsBridge }

        var lastError: Error = FeedError.needsBridge
        for candidate in fallbacks {
            guard let url = URL(string: candidate) else { continue }
            do {
                let articles = try await fetchFeed(url, sourceID: source.id, limit: limit)
                let note = bridge.isConfigured
                    ? "The X bridge did not answer — showing \(url.host ?? "the site feed") instead."
                    : "No X bridge configured — showing \(url.host ?? "the site feed") instead."
                return SourceLoadResult(articles: articles, note: note)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Telegram

    private static func loadTelegram(_ source: Source, limit: Int) async throws -> SourceLoadResult {
        guard let url = TelegramFeed.previewURL(for: source.endpoint) else {
            throw FeedError.badURL(source.endpoint)
        }

        do {
            let data = try await HTTP.shared.htmlData(from: url)
            let html = XMLSanitizer.text(from: data)
            let articles = TelegramFeed.parse(html: html,
                                              channel: source.endpoint,
                                              sourceID: source.id)
            guard !articles.isEmpty else { throw FeedError.empty }

            // The preview page is oldest-first; the feed wants newest-first,
            // and the tail of the page is the part worth keeping.
            let newest = articles.sorted { $0.sortDate > $1.sortDate }
            return SourceLoadResult(articles: Array(newest.prefix(limit)), note: nil)
        } catch {
            let fallbacks = source.fallbackFeeds.filter { !$0.isEmpty }
            guard !fallbacks.isEmpty else { throw error }
            for candidate in fallbacks {
                guard let url = URL(string: candidate) else { continue }
                if let articles = try? await fetchFeed(url, sourceID: source.id, limit: limit),
                   !articles.isEmpty {
                    return SourceLoadResult(articles: articles,
                                            note: "Telegram preview unavailable — using the backup feed.")
                }
            }
            throw error
        }
    }

    // MARK: - Steam

    private static func loadSteam(_ source: Source,
                                  steam: SteamContext,
                                  limit: Int) async throws -> SourceLoadResult {
        let games = Array(
            steam.games
                .sorted { $0.recencyRank > $1.recencyRank }
                .prefix(steam.maxGames)
        )
        guard !games.isEmpty else { throw FeedError.needsSteamLibrary }

        // One request per game, run together but bounded by `HTTP`'s gate. A
        // task group rather than a loop, because a twelve-game library is
        // twelve round trips and doing them in sequence is a visible wait.
        let collected = await withTaskGroup(of: [Article].self) { group -> [Article] in
            for game in games {
                group.addTask {
                    guard let items = try? await SteamAPI.shared.news(appID: game.appID,
                                                                      count: steam.itemsPerGame) else {
                        return []
                    }
                    return items.map { $0.article(sourceID: source.id, game: game) }
                }
            }
            var all: [Article] = []
            for await articles in group { all += articles }
            return all
        }

        guard !collected.isEmpty else { throw FeedError.empty }
        let sorted = collected.sorted { $0.sortDate > $1.sortDate }
        return SourceLoadResult(articles: Array(sorted.prefix(limit)), note: nil)
    }
}
