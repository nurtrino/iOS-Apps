import Foundation

/// Fetches one source, walking its fallback addresses.
enum FeedAPI {

    /// The first address that parses to items wins. The error kept on total
    /// failure is the *primary* endpoint's, because that is the address worth
    /// reporting — a fallback failing differently is noise.
    static func fetch(_ source: FeedSource) async throws -> [Article] {
        var primaryError: Error?

        for endpoint in source.allEndpoints {
            guard let url = URL(string: endpoint) else {
                if primaryError == nil { primaryError = FeedError.badURL(endpoint) }
                continue
            }
            do {
                let data = try await HTTP.shared.feedData(from: url)
                let feed = try FeedParser.parse(data)
                let articles = feed.items.map {
                    $0.article(sourceID: source.id, siteLink: feed.siteLink)
                }
                if !articles.isEmpty { return articles }
            } catch {
                if primaryError == nil { primaryError = error }
            }
        }
        throw primaryError ?? FeedError.empty
    }
}
