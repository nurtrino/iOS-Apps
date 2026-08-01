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

    /// Let the model hide a story it judges to belong in no section.
    ///
    /// **Off by default, including for the aggregator this was written for.** A
    /// section holding the odd sports headline is a small, visible annoyance. A
    /// section quietly missing most of a source is neither small nor visible, and
    /// that is what shipping this on by default produced. It stays as a toggle
    /// because the intent is right; it is not a default because the failure is
    /// asymmetric.
    ///
    /// Hidden stories are never deleted — they stay on the source's own screen
    /// and in Search — and the count now appears in the advisory line above the
    /// list, so a section cannot lose stories without saying so.
    var dropsUnsortable: Bool

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
         dropsUnsortable: Bool = false,
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
        self.dropsUnsortable = dropsUnsortable
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
        if let stored = try? container.decode(Bool.self, forKey: .dropsUnsortable) {
            dropsUnsortable = stored
        } else {
            dropsUnsortable = SourceCatalog.default(withID: id)?.dropsUnsortable ?? false
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
            // A straight political source now, not a classified one. It was
            // being scored per story and spread across three sections, which is
            // correct filing and was also the whole reason "where did CFP go"
            // kept coming up: a hundred links a day, split three ways, with the
            // low-signal ones dropping out entirely. It is a political
            // aggregator — so everything it posts goes to Politics, newest
            // first, and the section is the stream.
            topicMode: .fixed,
            fixedTopic: .politics,
            // Three addresses for one WordPress install. `?feed=rss2` is the
            // query-string form every WordPress serves regardless of permalink
            // settings, and it is worth having because a block is often on the
            // *path*: a WAF rule or a cache rule that refuses /feed/ will happily
            // serve the same bytes from the query form.
            fallbackFeeds: [
                "https://citizenfreepress.com/feed/rss/",
                "https://citizenfreepress.com/?feed=rss2",
            ],
            style: .wire,
            prefersWebPage: true,
            resolvesOutboundLink: true,
            isBuiltIn: true
        ),

        // --- Tech -----------------------------------------------------------
        //
        // All fixed to Tech, the same way Gaming works: these are single-subject
        // outlets, so there is nothing for the classifier to decide. Payload and
        // Next Spaceflight are tagged as space in `TechScreen` and surface in the
        // section's own space rail rather than the main tech wire.

        Source(
            id: "pirate-wires",
            name: "Pirate Wires",
            kind: .rss,
            endpoint: "https://www.piratewires.com/feed",
            topicMode: .fixed,
            fixedTopic: .tech,
            fallbackFeeds: [
                "https://www.piratewires.com/rss/",
                "https://piratewires.com/feed",
            ],
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "cryptogon",
            name: "Cryptogon",
            kind: .rss,
            endpoint: "https://www.cryptogon.com/feed/",
            topicMode: .fixed,
            fixedTopic: .tech,
            fallbackFeeds: [
                "https://cryptogon.com/feed/",
                "https://www.cryptogon.com/?feed=rss2",
            ],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "theregister",
            name: "The Register",
            kind: .rss,
            // The Register publishes an Atom feed of everything at this address;
            // the .co.uk host serves the identical bytes and covers a block on
            // one domain.
            endpoint: "https://www.theregister.com/headlines.atom",
            topicMode: .fixed,
            fixedTopic: .tech,
            fallbackFeeds: [
                "https://www.theregister.co.uk/headlines.atom",
                "https://www.theregister.com/Design/page/feeds.html",
            ],
            style: .wire,
            isBuiltIn: true
        ),
        Source(
            id: "payload-space",
            name: "Payload",
            kind: .rss,
            endpoint: "https://payloadspace.com/feed/",
            topicMode: .fixed,
            fixedTopic: .tech,
            fallbackFeeds: [
                "https://payloadspace.com/rss/",
                "https://payloadspace.com/?feed=rss2",
            ],
            style: .article,
            isBuiltIn: true
        ),
        Source(
            id: "nextspaceflight",
            name: "Next Spaceflight",
            kind: .rss,
            endpoint: "https://nextspaceflight.com/feed/",
            topicMode: .fixed,
            fixedTopic: .tech,
            fallbackFeeds: [
                "https://nextspaceflight.com/rss/",
                "https://nextspaceflight.com/news/feed/",
            ],
            style: .wire,
            isBuiltIn: true
        ),

        // --- War ----------------------------------------------------------

        Source(
            id: "middleeastspectator",
            name: "Middle East Spectator",
            kind: .telegram,
            endpoint: "MiddleEastSpectator",
            topicMode: .fixed,
            fixedTopic: .war,
            style: .wire,
            isBuiltIn: true
        ),

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
        // The frontline Telegram channel. Volume was the whole problem: it
        // needed its own block to stop it burying the analysis, then its own
        // rule to keep its threads out of the brief, and it was still the
        // loudest thing on the screen. Telegram is still a source *kind*, so
        // it can be added back by hand from More › Sources.
        "wfwitness",
    ]

    static func `default`(withID id: String) -> Source? {
        defaults.first { $0.id == id }
    }

    /// Bumped when a stored flag's *meaning* changes, not when a default does.
    ///
    /// The two are different and the difference is why stories went missing. A
    /// changed default is fine: the decoder falls back to it only when a stored
    /// catalog has no value for the key, so someone who edited a source keeps
    /// their edit and someone who never touched it gets the new behaviour.
    ///
    /// A changed *meaning* is not fine. `dropsUnsortable` used to say "the
    /// lexicon may hide what it has no words for" and now says "the model may
    /// hide what it judges to fit nowhere". A device that stored `true` under the
    /// first meaning never agreed to the second — but the value is present, so
    /// the decoder honours it and turning the shipped default off reaches nobody
    /// who already has the app. That is precisely the population the change was
    /// for. `CatalogStore` resets the affected flags when it sees an older
    /// revision.
    ///
    /// Revision 3: Citizen Free Press went from `.classified` to `.fixed`
    /// politics. That is a changed *meaning* for a stored source — an install
    /// that saved CFP as classified would keep splitting it across three
    /// sections forever, since the stored copy wins the merge — so the
    /// migration forces its filing back to what ships here.
    static let behaviourRevision = 3
}
