import Foundation

enum LivePlatform: String, Codable, CaseIterable, Identifiable {
    case youtube
    case x

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .x: return "X"
        }
    }

    var systemImage: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .x: return "at"
        }
    }
}

/// When a show is expected to be on.
///
/// A schedule is not how the app knows something is live — that is checked for
/// real. It decides when it is *worth checking*, and it lets the card say
/// "tonight at 10" instead of vanishing for twenty-three hours a day. A nightly
/// show that is off air is still the most useful thing to put on the screen if
/// it is back in an hour.
struct LiveSchedule: Codable, Hashable {

    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int>
    var startHour: Int
    var startMinute: Int
    var durationMinutes: Int
    /// The broadcaster's timezone, not the viewer's. A show that airs at 10pm
    /// Eastern airs at 10pm Eastern in July and in January, and hard-coding an
    /// offset gets it wrong for half the year.
    var timeZoneIdentifier: String

    /// How long before airtime the card starts appearing — and the app starts
    /// actually checking, because shows go live early.
    var leadMinutes: Int = 90

    static let easternNightly = LiveSchedule(
        weekdays: [1, 3, 4, 5, 6, 7],
        startHour: 22,
        startMinute: 0,
        durationMinutes: 180,
        timeZoneIdentifier: "America/New_York"
    )

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The most recent airtime at or before `date`, and the next one after it.
    func airtimes(around date: Date) -> (previous: Date?, next: Date?) {
        let calendar = self.calendar
        var previous: Date?
        var next: Date?

        // Seven days back and eight forward covers every weekly schedule, and
        // costs nothing to walk.
        for offset in -7...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let airtime = calendar.date(bySettingHour: startHour, minute: startMinute,
                                              second: 0, of: day) else { continue }

            if airtime <= date {
                if previous == nil || airtime > previous! { previous = airtime }
            } else if next == nil || airtime < next! {
                next = airtime
            }
        }
        return (previous, next)
    }

    /// True while the show is expected to be on, or about to be.
    func isInWindow(_ date: Date = Date()) -> Bool {
        let (previous, next) = airtimes(around: date)
        if let previous, date < previous.addingTimeInterval(TimeInterval(durationMinutes * 60)) {
            return true
        }
        if let next, next.timeIntervalSince(date) <= TimeInterval(leadMinutes * 60) {
            return true
        }
        return false
    }

    func nextAirtime(after date: Date = Date()) -> Date? {
        airtimes(around: date).next
    }

    /// "Tonight at 10:00 PM", "Tomorrow at 10:00 PM", "Thu at 10:00 PM".
    func nextAirtimeDescription(from date: Date = Date()) -> String? {
        guard let next = nextAirtime(after: date) else { return nil }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.autoupdatingCurrent
        timeFormatter.timeZone = TimeZone.autoupdatingCurrent
        timeFormatter.setLocalizedDateFormatFromTemplate("jmm")
        let time = timeFormatter.string(from: next)

        // Rendered in the *viewer's* calendar: a 10pm Eastern show is "tonight"
        // for someone in New York and "tomorrow" for someone in London, and the
        // card should say whichever is true where they are.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone.autoupdatingCurrent

        if local.isDateInToday(next) { return "Tonight at \(time)" }
        if local.isDateInTomorrow(next) { return "Tomorrow at \(time)" }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale.autoupdatingCurrent
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        return "\(dayFormatter.string(from: next)) at \(time)"
    }
}

/// A stream the War screen watches for.
struct LiveChannel: Identifiable, Codable, Hashable {

    var id: String
    var name: String
    var blurb: String
    var platform: LivePlatform
    /// A YouTube channel id (`UC…`) or handle (`@name`); an X handle for `.x`.
    var reference: String
    /// Where to send someone when the app cannot play it itself.
    var externalHandle: String
    var schedule: LiveSchedule?
    /// Which section's rail this appears in.
    ///
    /// War was the only one with a rail when this shipped, so the topic was
    /// implicit. Markets wants one too — a rolling finance channel is the same
    /// idea as a rolling war channel, and for the same reason: when something is
    /// happening you want the coverage, not a headline about it an hour later.
    var topic: Topic
    var isEnabled: Bool

    init(id: String,
         name: String,
         blurb: String,
         platform: LivePlatform,
         reference: String,
         externalHandle: String = "",
         schedule: LiveSchedule? = nil,
         topic: Topic = .war,
         isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.platform = platform
        self.reference = reference
        self.externalHandle = externalHandle
        self.schedule = schedule
        self.topic = topic
        self.isEnabled = isEnabled
    }

    /// Older stored copies have no topic. Defaulting to War preserves what those
    /// installs already showed, and the Markets channels arrive as new ids.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Read into a local first. `LiveCatalog.defaults.first { $0.id == id }`
        // below reads `id` inside a closure, and a closure in an initialiser
        // captures `self` — which Swift refuses while any property is still
        // uninitialised, however obviously safe the read looks.
        let storedID = try container.decode(String.self, forKey: .id)
        id = storedID
        name = try container.decode(String.self, forKey: .name)
        blurb = (try? container.decode(String.self, forKey: .blurb)) ?? ""
        platform = (try? container.decode(LivePlatform.self, forKey: .platform)) ?? .youtube
        reference = (try? container.decode(String.self, forKey: .reference)) ?? ""
        externalHandle = (try? container.decode(String.self, forKey: .externalHandle)) ?? ""
        schedule = try? container.decode(LiveSchedule.self, forKey: .schedule)
        topic = (try? container.decode(Topic.self, forKey: .topic))
            ?? LiveCatalog.defaults.first { $0.id == storedID }?.topic
            ?? .war
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
    }

    /// Channels with no schedule are checked whenever the screen is open;
    /// scheduled ones only around their airtime.
    var shouldCheckNow: Bool {
        guard let schedule else { return true }
        return schedule.isInWindow()
    }

    var externalURL: URL? {
        switch platform {
        case .x:
            return XBridge.profileURL(handle: externalHandle.isEmpty ? reference : externalHandle)
        case .youtube:
            return YouTubeLive.channelURL(reference: reference)
        }
    }
}

/// The channels the app ships with.
enum LiveCatalog {

    static let defaults: [LiveChannel] = [
        LiveChannel(
            id: "nawfal",
            name: "Mario Nawfal",
            blurb: "Roundtable — breaking news, rolling coverage",
            platform: .youtube,
            reference: "@MarioNawfal",
            externalHandle: "MarioNawfal"
        ),
        LiveChannel(
            id: "lookner",
            name: "Lookner",
            blurb: "Live breaking news coverage",
            platform: .youtube,
            reference: "UClJtyMSnpVHyNpmqc2WJjVQ",
            externalHandle: "lookner"
        ),
        LiveChannel(
            id: "enforcer",
            name: "The Enforcer",
            blurb: "Nightly war news stream",
            platform: .youtube,
            reference: "@EnforcerOfficial",
            externalHandle: "ItsTheEnforcer",
            // Nightly except Monday. The exact hour has moved before, so this
            // is editable and the lead time is generous — the schedule only
            // decides when to start checking, and the live check is what
            // actually decides whether the card says LIVE.
            schedule: LiveSchedule.easternNightly
        ),
        // --- Markets ---------------------------------------------------------
        //
        // Bloomberg Television runs its channel free and unencrypted on YouTube,
        // twenty-four hours a day. It is the closest thing to "Bloomberg on in
        // the corner" that costs nothing and needs no account, which is exactly
        // what a markets section wants during a selloff.
        LiveChannel(
            id: "bloomberg-tv",
            name: "Bloomberg Television",
            blurb: "Rolling markets coverage, 24/7",
            platform: .youtube,
            reference: "@markets",
            externalHandle: "markets",
            topic: .economics
        ),
        // A second one, because a single stream going dark leaves the section
        // with an empty rail and no explanation.
        LiveChannel(
            id: "yahoo-finance",
            name: "Yahoo Finance",
            blurb: "Market open to close",
            platform: .youtube,
            reference: "@YahooFinance",
            externalHandle: "YahooFinance",
            topic: .economics
        ),
        LiveChannel(
            id: "schwab-network",
            name: "Schwab Network",
            blurb: "Trading day coverage",
            platform: .youtube,
            reference: "@SchwabNetwork",
            externalHandle: "SchwabNetwork",
            topic: .economics,
            isEnabled: false
        ),

        LiveChannel(
            id: "nawfal-x",
            name: "Mario Nawfal on X",
            blurb: "Spaces and X livestreams — opens in X",
            platform: .x,
            reference: "MarioNawfal",
            externalHandle: "MarioNawfal",
            isEnabled: false
        ),
    ]
}

/// What a check found.
struct LiveState: Codable, Hashable {
    var isLive: Bool
    var videoID: String?
    var title: String?
    var thumbnailURL: URL?
    var checked: Date

    static func offline(at date: Date = Date()) -> LiveState {
        LiveState(isLive: false, videoID: nil, title: nil, thumbnailURL: nil, checked: date)
    }
}
