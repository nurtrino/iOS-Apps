import Foundation

/// How a source is fetched.
///
/// Flat rather than an enum with associated values, because sources are edited
/// in a form: the kind is a picker and `endpoint` is a text field whose label
/// changes. An enum with payloads would model it more precisely and make that
/// screen twice the code.
enum SourceKind: String, Codable, CaseIterable, Identifiable {
    /// `endpoint` is a feed URL. RSS 2.0, Atom and RDF all parse here.
    case rss
    /// `endpoint` is a channel name; the public web preview is scraped.
    case telegram
    /// `endpoint` is a handle. Needs a bridge — see `XBridge`.
    case x
    /// `endpoint` is unused; the Steam library drives it.
    case steam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rss: return "RSS feed"
        case .telegram: return "Telegram channel"
        case .x: return "X account"
        case .steam: return "Steam library"
        }
    }

    var endpointLabel: String {
        switch self {
        case .rss: return "Feed URL"
        case .telegram: return "Channel"
        case .x: return "Handle"
        case .steam: return "Configured in Settings › Steam"
        }
    }

    var systemImage: String {
        switch self {
        case .rss: return "dot.radiowaves.up.forward"
        case .telegram: return "paperplane"
        case .x: return "at"
        case .steam: return "gamecontroller"
        }
    }
}

/// How a source's items want to be shown.
enum SourceStyle: String, Codable, CaseIterable, Identifiable {
    /// Headline, image, dek. For articles you read.
    case article
    /// One dense line. For a wire you scan.
    case wire

    var id: String { rawValue }

    var title: String {
        switch self {
        case .article: return "Article"
        case .wire: return "Wire"
        }
    }
}

/// Whether a source's topic is known up front or has to be worked out per item.
enum TopicMode: String, Codable, CaseIterable, Identifiable {
    /// Everything this source publishes is the same topic. True of a defense
    /// outlet, a Telegram war channel, a gaming account — and it makes those
    /// sources free to route, with no chance of a misfile.
    case fixed
    /// A general outlet. Every item is scored individually.
    case classified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed: return "Always one topic"
        case .classified: return "Sort each story"
        }
    }
}

/// One feed the app pulls from.
struct Source: Identifiable, Codable, Hashable {

    var id: String
    var name: String
    var kind: SourceKind
    /// Meaning depends on `kind` — see `SourceKind.endpointLabel`.
    var endpoint: String

    var topicMode: TopicMode
    /// The topic for a `.fixed` source, and the fallback for a `.classified`
    /// one when nothing in the text scores high enough to call.
    var fixedTopic: Topic
    /// A thumb on the scale for a `.classified` source — what it usually
    /// publishes. Nil means genuinely no lean.
    var topicPrior: Topic?

    /// Plain RSS URLs to fall back to when `endpoint` cannot be reached.
    ///
    /// This is what keeps the X sections useful with no bridge configured, and
    /// what covers a feed host that has moved. Tried in order, and the first
    /// one that yields items wins.
    var fallbackFeeds: [String]
    var style: SourceStyle

    /// Skip the reader and open the publisher's page.
    ///
    /// For a link aggregator this is the only behaviour that makes sense. Its
    /// feed items *are* links — the headline points at somebody else's article
    /// and the description is empty or a one-line teaser — so the reader has
    /// nothing to render and shows a stub with a button on it. Going straight
    /// to the page turns two taps and a dead end into one tap.
    var prefersWebPage: Bool

    /// Follow the item's permalink through to the article it links to.
    ///
    /// Only meaningful for an aggregator, whose permalink is a stub page
    /// wrapping somebody else's link. See `LinkResolver`.
    var resolvesOutboundLink: Bool

    var isEnabled: Bool
    /// Built-in sources can be disabled and edited but not deleted, so a bad
    /// edit is always one "Reset" away from working again.
    var isBuiltIn: Bool

    init(id: String,
         name: String,
         kind: SourceKind,
         endpoint: String,
         topicMode: TopicMode = .fixed,
         fixedTopic: Topic = .politics,
         topicPrior: Topic? = nil,
         fallbackFeeds: [String] = [],
         style: SourceStyle = .article,
         prefersWebPage: Bool = false,
         resolvesOutboundLink: Bool = false,
         isEnabled: Bool = true,
         isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.topicMode = topicMode
        self.fixedTopic = fixedTopic
        self.topicPrior = topicPrior
        self.fallbackFeeds = fallbackFeeds
        self.style = style
        self.prefersWebPage = prefersWebPage
        self.resolvesOutboundLink = resolvesOutboundLink
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    /// What the source shows under a headline.
    var attribution: String {
        switch kind {
        case .telegram: return "t.me/\(endpoint)"
        case .x: return "@\(endpoint)"
        default: return name
        }
    }

    /// Topics this source can put a story into — what the Sources screen shows
    /// as its destination.
    var reachableTopics: [Topic] {
        topicMode == .fixed ? [fixedTopic] : Topic.classifiable
    }

    /// Decoded leniently so a source stored by an older build — before a field
    /// existed — still loads instead of taking the whole catalog down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = (try? container.decode(SourceKind.self, forKey: .kind)) ?? .rss
        endpoint = (try? container.decode(String.self, forKey: .endpoint)) ?? ""
        topicMode = (try? container.decode(TopicMode.self, forKey: .topicMode)) ?? .fixed
        fixedTopic = (try? container.decode(Topic.self, forKey: .fixedTopic)) ?? .politics
        topicPrior = try? container.decode(Topic.self, forKey: .topicPrior)
        fallbackFeeds = (try? container.decode([String].self, forKey: .fallbackFeeds)) ?? []
        style = (try? container.decode(SourceStyle.self, forKey: .style)) ?? .article
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        isBuiltIn = (try? container.decode(Bool.self, forKey: .isBuiltIn)) ?? false

        // A field added after someone already has a catalog on disk needs a
        // better default than `false`, or the new behaviour ships to nobody who
        // already has the app — the stored copy simply has no value for the key
        // and quietly wins. Falling back to what the app *ships* for this
        // source id means an existing install picks the change up, while a
        // source the user actually edited keeps whatever they set.
        if let stored = try? container.decode(Bool.self, forKey: .prefersWebPage) {
            prefersWebPage = stored
        } else {
            prefersWebPage = SourceCatalog.default(withID: id)?.prefersWebPage ?? false
        }
        if let stored = try? container.decode(Bool.self, forKey: .resolvesOutboundLink) {
            resolvesOutboundLink = stored
        } else {
            resolvesOutboundLink = SourceCatalog.default(withID: id)?.resolvesOutboundLink ?? false
        }
    }
}

/// The sources the app ships with.
///
/// Each one carries a fallback so a topic is never empty just because its
/// primary host is having a day. The X sources fall back to real RSS
/// deliberately: X has no public read API, so without a bridge configured they
/// would otherwise show nothing at all.
enum SourceCatalog {

    static let defaults: [Source] = [

        // --- General outlets, sorted per story ---------------------------

        Source(
            id: "zerohedge",
            name: "ZeroHedge",
            kind: .rss,
            endpoint: "https://cms.zerohedge.com/fullrss2.xml",
            topicMode: .classified,
            fixedTopic: .economics,
            topicPrior: .economics,
            fallbackFeeds: [
                "https://feeds.feedburner.com/zerohedge/feed",
                "https://www.zerohedge.com/fullrss2.xml",
            ],
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "citizenfreepress",
            name: "Citizen Free Press",
            kind: .rss,
            endpoint: "https://citizenfreepress.com/feed/",
            topicMode: .classified,
            fixedTopic: .politics,
            topicPrior: .politics,
            fallbackFeeds: ["https://citizenfreepress.com/feed/rss/"],
            style: .wire,
            prefersWebPage: true,
            resolvesOutboundLink: true,
            isBuiltIn: true
        ),

        // --- War ----------------------------------------------------------

        Source(
            id: "twz",
            name: "The War Zone",
            kind: .rss,
            endpoint: "https://www.twz.com/feed",
            topicMode: .fixed,
            fixedTopic: .war,
            fallbackFeeds: [
                "https://www.twz.com/rss",
                "https://www.thedrive.com/the-war-zone/feed",
            ],
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "wfwitness",
            name: "WarFront Witness",
            kind: .telegram,
            endpoint: "wfwitness",
            topicMode: .fixed,
            fixedTopic: .war,
            style: .wire,
            isBuiltIn: true
        ),

        // --- Gaming ---------------------------------------------------------

        Source(
            id: "steam",
            name: "Steam",
            kind: .steam,
            endpoint: "",
            topicMode: .fixed,
            fixedTopic: .gaming,
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "charlieintel-rss",
            name: "CharlieIntel",
            kind: .rss,
            endpoint: "https://www.charlieintel.com/feed/",
            topicMode: .fixed,
            fixedTopic: .gaming,
            fallbackFeeds: ["https://charlieintel.com/feed/"],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "gematsu",
            name: "Gematsu",
            kind: .rss,
            // Announcements, trailers and release dates — the closest thing in
            // RSS to what the deals-and-drops X accounts were being read for.
            endpoint: "https://www.gematsu.com/feed",
            topicMode: .fixed,
            fixedTopic: .gaming,
            fallbackFeeds: ["https://gematsu.com/feed"],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "vgc",
            name: "Video Games Chronicle",
            kind: .rss,
            endpoint: "https://www.videogameschronicle.com/feed/",
            topicMode: .fixed,
            fixedTopic: .gaming,
            fallbackFeeds: ["https://www.videogameschronicle.com/rss/"],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "pcgamer",
            name: "PC Gamer",
            kind: .rss,
            endpoint: "https://www.pcgamer.com/rss/",
            topicMode: .fixed,
            fixedTopic: .gaming,
            fallbackFeeds: ["https://www.pcgamer.com/feed/"],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "eurogamer",
            name: "Eurogamer",
            kind: .rss,
            endpoint: "https://www.eurogamer.net/feed",
            topicMode: .fixed,
            fixedTopic: .gaming,
            fallbackFeeds: ["https://www.eurogamer.net/?format=rss"],
            style: .wire,
            isEnabled: false,
            isBuiltIn: true
        ),
        Source(
            id: "rps",
            name: "Rock Paper Shotgun",
            kind: .rss,
            endpoint: "https://www.rockpapershotgun.com/feed",
            topicMode: .fixed,
            fixedTopic: .gaming,
            style: .wire,
            isEnabled: false,
            isBuiltIn: true
        ),
    ]

    /// Built-ins that used to ship and no longer do.
    ///
    /// Merging only ever *adds* to a stored catalog, so a source removed from
    /// this file would otherwise live forever on any device that already had
    /// it — the X sources would still be there, still failing over to a backup
    /// feed, on exactly the installs this change is meant to fix. Listing them
    /// here is what actually retires them.
    static let retired: Set<String> = [
        "zerohedge-x",
        "gaming-x",
        "gaming-x-genki",
        "pirat-nation",
        // Replaced by `charlieintel-rss`. A new id rather than a change of
        // kind on the old one, because the stored copy wins the merge and
        // would have kept it an X source.
        "charlieintel",
    ]

    static func `default`(withID id: String) -> Source? {
        defaults.first { $0.id == id }
    }
}
