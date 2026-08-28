import Foundation

/// One feed the app pulls from.
struct FeedSource: Identifiable, Hashable {
    let id: String
    let name: String
    /// The primary feed address.
    let endpoint: String
    /// Tried in order when `endpoint` cannot be reached or parses to nothing.
    /// This is what covers a feed host that has moved or a WAF rule that
    /// blocks one path but not another.
    let fallbackFeeds: [String]

    init(id: String, name: String, endpoint: String, fallbackFeeds: [String] = []) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.fallbackFeeds = fallbackFeeds
    }

    /// Every address this source can be read from, primary first.
    var allEndpoints: [String] { [endpoint] + fallbackFeeds }
}

/// The sources the app ships with — a hand-picked economics desk.
///
/// Each one carries fallbacks so the merged feed is never empty just because a
/// primary host is having a day. The ZeroHedge addresses are inherited from a
/// sibling app in this repo where they were verified against the live site.
enum FeedCatalog {

    static let sources: [FeedSource] = [

        FeedSource(
            id: "zerohedge",
            name: "ZeroHedge",
            // The CMS host serves the full feed without the Cloudflare
            // challenge the www host sometimes puts in front of it.
            endpoint: "https://cms.zerohedge.com/fullrss2.xml",
            fallbackFeeds: [
                "https://feeds.feedburner.com/zerohedge/feed",
                "https://www.zerohedge.com/fullrss2.xml",
            ]
        ),
        FeedSource(
            id: "cnbc-economy",
            name: "CNBC Economy",
            // CNBC's long-standing section feeds; 20910258 is Economy and
            // 100003114 is Top News.
            endpoint: "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=20910258",
            fallbackFeeds: [
                "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114",
            ]
        ),
        FeedSource(
            id: "marketwatch",
            name: "MarketWatch",
            // MarketWatch's feeds moved off feeds.marketwatch.com to Dow
            // Jones's shared host; the old address now 404s.
            endpoint: "https://feeds.content.dowjones.io/public/rss/mw_topstories",
            fallbackFeeds: [
                "https://feeds.content.dowjones.io/public/rss/mw_realtimeheadlines",
                "https://feeds.content.dowjones.io/public/rss/mw_marketpulse",
            ]
        ),
        FeedSource(
            id: "bbc-business",
            name: "BBC Business",
            endpoint: "https://feeds.bbci.co.uk/news/business/rss.xml",
            fallbackFeeds: [
                "https://feeds.bbci.co.uk/news/business/economy/rss.xml",
            ]
        ),
        FeedSource(
            id: "fxstreet",
            name: "FXStreet",
            endpoint: "https://www.fxstreet.com/rss/news",
            fallbackFeeds: [
                "https://www.fxstreet.com/rss",
            ]
        ),
        FeedSource(
            id: "investing-economy",
            name: "Investing.com",
            // Investing.com numbers its section feeds; 14 is economy news.
            // The host is fronted by a bot-sensitive CDN, hence the browser
            // User-Agent in `HTTP` and two fallback addresses.
            endpoint: "https://www.investing.com/rss/news_14.rss",
            fallbackFeeds: [
                "https://www.investing.com/rss/news_95.rss",
                "https://www.investing.com/rss/news.rss",
            ]
        ),
        FeedSource(
            id: "calculated-risk",
            name: "Calculated Risk",
            endpoint: "https://feeds.feedburner.com/CalculatedRisk",
            fallbackFeeds: [
                "https://www.calculatedriskblog.com/feeds/posts/default?alt=rss",
            ]
        ),
        FeedSource(
            id: "wolfstreet",
            name: "Wolf Street",
            endpoint: "https://wolfstreet.com/feed/",
            fallbackFeeds: [
                // `?feed=rss2` is the query-string form every WordPress serves
                // regardless of permalink settings — a WAF block is often on
                // the *path*, and the query form serves the same bytes.
                "https://wolfstreet.com/?feed=rss2",
            ]
        ),
        FeedSource(
            id: "naked-capitalism",
            name: "Naked Capitalism",
            endpoint: "https://www.nakedcapitalism.com/feed",
            fallbackFeeds: [
                "https://www.nakedcapitalism.com/?feed=rss2",
            ]
        ),
        FeedSource(
            id: "economist-finance",
            name: "The Economist · Finance",
            endpoint: "https://www.economist.com/finance-and-economics/rss.xml",
            fallbackFeeds: [
                "https://www.economist.com/the-world-this-week/rss.xml",
            ]
        ),
    ]

    static func source(withID id: String) -> FeedSource? {
        sources.first { $0.id == id }
    }

    static var allIDs: Set<String> { Set(sources.map { $0.id }) }
}
