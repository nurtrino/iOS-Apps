import Foundation

/// One item in a feed, whatever produced it.
///
/// RSS articles, Telegram posts, X posts and Steam patch notes all land here.
/// They differ in what they carry — a Telegram post has no title, a Steam item
/// has no image — so everything but the identity is optional and the UI decides
/// what to do with what is present rather than each source getting its own row
/// type.
struct Article: Identifiable, Hashable, Codable {

    /// Stable across refreshes, and unique across sources.
    ///
    /// This is what read state and saved articles key on, so it must survive a
    /// feed re-fetch. Derived from the source plus the item's own identity —
    /// its guid if it has one, otherwise its link, otherwise a hash of the
    /// text. Never the array index and never the publication date: both change
    /// under you and turn every refresh into a screen of "new" items.
    let id: String

    let sourceID: String
    let title: String
    /// Plain text, already stripped of markup, for the row.
    let summary: String
    /// The original markup, kept for the in-app reader to lay out properly.
    let bodyHTML: String?
    /// Where the story lives.
    ///
    /// A `var` because an aggregator's feed gives its own permalink here, and
    /// the destination it points at is better — see `LinkResolver`. The id is
    /// derived before any rewrite, so identity stays put.
    var link: URL?
    let imageURL: URL?
    /// A playable file, when the source carries one directly.
    ///
    /// Telegram serves video posts as a plain MP4 on its CDN, so those can be
    /// played rather than bounced out to the web page — which for a video post
    /// is the whole content.
    let videoURL: URL?
    let author: String?
    let published: Date?

    /// A short qualifier shown next to the source name — the game a Steam item
    /// is about, the handle a post came from. Nil when the source name says it
    /// all.
    let context: String?

    init(id: String,
         sourceID: String,
         title: String,
         summary: String = "",
         bodyHTML: String? = nil,
         link: URL? = nil,
         imageURL: URL? = nil,
         videoURL: URL? = nil,
         author: String? = nil,
         published: Date? = nil,
         context: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.summary = summary
        self.bodyHTML = bodyHTML
        self.link = link
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.author = author
        self.published = published
        self.context = context
    }

    /// A headline, for sources that carry no separate title.
    ///
    /// Telegram and X posts are body-only. Rather than render an empty title,
    /// the first sentence-ish run of the body becomes one, which is what every
    /// reader does with a microblog post and what makes those rows scannable
    /// next to real articles.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return Article.headline(from: summary)
    }

    /// True when the title *is* the body, so a row showing both would print the
    /// same sentence twice.
    var summaryDuplicatesTitle: Bool {
        title.isEmpty || Article.normalise(summary) == Article.normalise(title)
    }

    static func headline(from body: String, limit: Int = 140) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }

        // Prefer a natural break — the first line, or the first sentence —
        // before falling back to a hard truncation mid-word.
        if let newline = trimmed.firstIndex(of: "\n") {
            let first = String(trimmed[trimmed.startIndex..<newline])
                .trimmingCharacters(in: .whitespaces)
            if first.count >= 12 { return String(first.prefix(limit)) }
        }
        if trimmed.count <= limit { return trimmed }

        // The last sentence end inside the window, as long as it is not so
        // early that the "sentence" is really an abbreviation. Twenty
        // characters is enough to reject "Mr." and short enough to accept a
        // genuinely terse first line, which is most of what a wire post is.
        let window = trimmed.prefix(limit)
        if let stop = window.lastIndex(where: { ".!?".contains($0) }),
           window.distance(from: window.startIndex, to: stop) >= 20 {
            return String(window[window.startIndex...stop])
        }
        if let space = window.lastIndex(of: " ") {
            return String(window[window.startIndex..<space]) + "…"
        }
        return String(window) + "…"
    }

    private static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The key two copies of the same story collide on.
    ///
    /// Citizen Free Press links out to the same wire stories ZeroHedge runs, so
    /// a merged section shows duplicates unless something folds them together.
    /// The URL is the honest identity, minus the tracking parameters that make
    /// two links to one page look different.
    var dedupeKey: String {
        if let link, let canonical = URLCanonical.key(for: link) { return canonical }
        return "title:" + Article.normalise(displayTitle)
    }

    /// Sorting fallback. An item with no date sorts as if it were old rather
    /// than pinning itself to the top of every merged feed forever.
    var sortDate: Date {
        published ?? .distantPast
    }
}

/// A hash that means the same thing on every launch.
///
/// `String.hashValue` cannot be used for anything persisted: Swift seeds it
/// randomly per process, so an article id derived from it changes every time
/// the app starts and read state silently resets. FNV-1a is small, has no
/// dependencies, and — the only property that matters here — is deterministic.
enum StableHash {

    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// Reduces a URL to the part that identifies the page.
enum URLCanonical {

    /// Parameters that identify the *referrer*, not the page.
    private static let noise: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_name", "fbclid", "gclid", "msclkid", "igshid", "mc_cid",
        "mc_eid", "ref", "referrer", "source", "amp", "__twitter_impression",
    ]

    static func key(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { return nil }

        if let items = components.queryItems {
            let kept = items.filter { !noise.contains($0.name.lowercased()) }
            components.queryItems = kept.isEmpty ? nil : kept.sorted { $0.name < $1.name }
        }
        components.fragment = nil

        // www and a trailing slash are formatting, not identity.
        var normalisedHost = host.lowercased()
        if normalisedHost.hasPrefix("www.") { normalisedHost.removeFirst(4) }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return normalisedHost + path + query
    }
}
