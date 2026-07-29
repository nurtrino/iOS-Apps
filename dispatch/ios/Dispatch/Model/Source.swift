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

/// One feed the app pulls from.
struct Source: Identifiable, Codable, Hashable {

    var id: String
    var name: String
    var kind: SourceKind
    var sectionID: String
    /// Meaning depends on `kind` — see `SourceKind.endpointLabel`.
    var endpoint: String
    /// Plain RSS URLs to fall back to when `endpoint` cannot be reached.
    ///
    /// This is what keeps the X sections useful with no bridge configured, and
    /// what covers a feed host that has moved. Tried in order, and the first
    /// one that yields items wins.
    var fallbackFeeds: [String]
    var style: SourceStyle
    var isEnabled: Bool
    /// Built-in sources can be disabled and edited but not deleted, so a bad
    /// edit is always one "Reset" away from working again.
    var isBuiltIn: Bool

    init(id: String,
         name: String,
         kind: SourceKind,
         sectionID: String,
         endpoint: String,
         fallbackFeeds: [String] = [],
         style: SourceStyle = .article,
         isEnabled: Bool = true,
         isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sectionID = sectionID
        self.endpoint = endpoint
        self.fallbackFeeds = fallbackFeeds
        self.style = style
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

    /// Decoded leniently so a source stored by an older build — before a field
    /// existed — still loads instead of taking the whole catalog down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = (try? container.decode(SourceKind.self, forKey: .kind)) ?? .rss
        sectionID = (try? container.decode(String.self, forKey: .sectionID)) ?? SectionCatalog.topID
        endpoint = (try? container.decode(String.self, forKey: .endpoint)) ?? ""
        fallbackFeeds = (try? container.decode([String].self, forKey: .fallbackFeeds)) ?? []
        style = (try? container.decode(SourceStyle.self, forKey: .style)) ?? .article
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        isBuiltIn = (try? container.decode(Bool.self, forKey: .isBuiltIn)) ?? false
    }
}

/// A tab in the feed: a name and the sources that fill it.
struct FeedSection: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var systemImage: String
    var isBuiltIn: Bool

    init(id: String, title: String, systemImage: String, isBuiltIn: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isBuiltIn = isBuiltIn
    }
}

/// The sections the app ships with.
enum SectionCatalog {

    /// Not a real section — a view over every other one, merged and sorted.
    /// Held as a constant because several places have to special-case it.
    static let topID = "top"

    static let defaults: [FeedSection] = [
        FeedSection(id: topID, title: "Top", systemImage: "newspaper", isBuiltIn: true),
        FeedSection(id: "wire", title: "Wire", systemImage: "bolt.horizontal", isBuiltIn: true),
        FeedSection(id: "markets", title: "Markets",
                    systemImage: "chart.line.uptrend.xyaxis", isBuiltIn: true),
        FeedSection(id: "frontpage", title: "Front Page",
                    systemImage: "list.bullet.rectangle", isBuiltIn: true),
        FeedSection(id: "defense", title: "Defense", systemImage: "shield", isBuiltIn: true),
        FeedSection(id: "gaming", title: "Gaming", systemImage: "gamecontroller", isBuiltIn: true),
    ]
}

/// The sources the app ships with.
///
/// Each one carries a fallback so a section is never empty just because its
/// primary host is having a day. The two X sources fall back to real RSS
/// deliberately: X has no public read API, so without a bridge configured they
/// would otherwise show nothing at all.
enum SourceCatalog {

    static let defaults: [Source] = [
        Source(
            id: "zerohedge",
            name: "ZeroHedge",
            kind: .rss,
            sectionID: "markets",
            endpoint: "https://cms.zerohedge.com/fullrss2.xml",
            fallbackFeeds: [
                "https://feeds.feedburner.com/zerohedge/feed",
                "https://www.zerohedge.com/fullrss2.xml",
            ],
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "zerohedge-x",
            name: "ZeroHedge Wire",
            kind: .x,
            sectionID: "wire",
            endpoint: "zerohedge",
            // Without a bridge this is the whole source, so it points at the
            // fullest feed available: titles alone still make a usable wire.
            fallbackFeeds: [
                "https://cms.zerohedge.com/fullrss2.xml",
                "https://feeds.feedburner.com/zerohedge/feed",
            ],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "citizenfreepress",
            name: "Citizen Free Press",
            kind: .rss,
            sectionID: "frontpage",
            endpoint: "https://citizenfreepress.com/feed/",
            fallbackFeeds: ["https://citizenfreepress.com/feed/rss/"],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "twz",
            name: "The War Zone",
            kind: .rss,
            sectionID: "defense",
            endpoint: "https://www.twz.com/feed",
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
            sectionID: "defense",
            endpoint: "wfwitness",
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "steam",
            name: "Steam",
            kind: .steam,
            sectionID: "gaming",
            endpoint: "",
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "gaming-x",
            name: "Gaming Wire",
            kind: .x,
            sectionID: "gaming",
            // Wario64 is the long-running high-signal account for releases,
            // deals and patch news; Genki covers the Japanese side.
            endpoint: "Wario64",
            fallbackFeeds: [
                "https://www.pcgamer.com/rss/",
                "https://www.rockpapershotgun.com/feed",
            ],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "gaming-x-genki",
            name: "Genki",
            kind: .x,
            sectionID: "gaming",
            endpoint: "Genki_JPN",
            fallbackFeeds: ["https://www.gematsu.com/feed"],
            style: .wire,
            isEnabled: false,
            isBuiltIn: true
        ),
    ]

    static func `default`(withID id: String) -> Source? {
        defaults.first { $0.id == id }
    }
}
