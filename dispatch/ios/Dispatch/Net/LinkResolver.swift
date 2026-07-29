import Foundation

/// Follows an aggregator's permalink through to the article it points at.
///
/// A link aggregator publishes a stub: `citizenfreepress.com/<slug>/` is a page
/// with a headline and a "Go To Article — youtube.com" link on it, and nothing
/// else. Opening the permalink shows the stub, which is a dead end with an
/// extra tap on it.
///
/// Two attempts, cheapest first:
///
/// 1. **From the feed.** If the item's own description carries the outbound
///    anchor — most aggregators' do — it costs nothing and is applied when the
///    feed is parsed.
/// 2. **From the page, on tap.** When the description does not carry it, the
///    permalink is fetched and the anchor read out of it. One request, and only
///    for a story someone actually opened — resolving all forty at refresh
///    would be forty requests for the thirty-nine nobody reads.
///
/// Results are cached for the session, so going back and re-opening is instant,
/// and anything that fails falls back to the permalink rather than to nothing.
actor LinkResolver {

    static let shared = LinkResolver()

    private var cache: [String: URL] = [:]
    /// Permalinks already tried and found to have no outbound link, so a second
    /// tap does not repeat the request.
    private var misses: Set<String> = []

    func destination(for article: Article, source: Source?) async -> URL? {
        guard let link = article.link else { return nil }
        guard source?.resolvesOutboundLink == true else { return link }

        let key = link.absoluteString
        if let cached = cache[key] { return cached }
        if misses.contains(key) { return link }

        guard let data = try? await HTTP.shared.htmlData(from: link) else { return link }
        let html = XMLSanitizer.text(from: data)

        guard let outbound = HTMLText.outboundLink(in: html,
                                                   relativeTo: link,
                                                   excludingHost: link.host) else {
            misses.insert(key)
            return link
        }
        cache[key] = outbound
        return outbound
    }

    /// Seeds the cache from what the feed already gave us, so the common case
    /// never makes a request at all.
    func remember(_ destination: URL, for permalink: URL) {
        cache[permalink.absoluteString] = destination
    }

    func clear() {
        cache = [:]
        misses = []
    }
}
