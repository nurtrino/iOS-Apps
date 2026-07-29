import Foundation

/// Dates, as feeds actually write them.
///
/// The spec says RSS uses RFC 822 and Atom uses RFC 3339. In practice a feed
/// reader sees neither cleanly: two-digit years, named zones outside the RFC
/// list, missing seconds, a "GMT" that should have been "+0000", ISO stamps
/// with and without fractional seconds. Getting this wrong is not subtle —
/// every item with an unparsed date sorts to the bottom of a merged feed and
/// looks like it never updates.
///
/// So: a list of formats, tried in the order they turn up in the wild, all
/// pinned to `en_US_POSIX` and UTC. A fixed locale matters — a device set to
/// Arabic parses "Tue, 29 Jul" as nothing at all with the system locale.
enum FeedDate {

    private static let formats = [
        // RFC 822 / 2822, the RSS mainstream.
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yy HH:mm:ss Z",
        // ISO 8601 shapes that `ISO8601DateFormatter` is fussy about.
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    ]

    private static let formatters: [DateFormatter] = formats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = isoWithFractional.date(from: trimmed) { return date }
        if let date = isoPlain.date(from: trimmed) { return date }

        let normalised = normaliseZone(in: trimmed)
        for formatter in formatters {
            if let date = formatter.date(from: normalised) { return date }
        }

        // Some Telegram and API payloads are bare Unix seconds.
        if let seconds = TimeInterval(trimmed), seconds > 100_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// Rewrites the zone abbreviations `DateFormatter` will not take.
    ///
    /// `Z` in a format string wants a numeric offset; a feed that ends its
    /// timestamps in "EST" or the (technically invalid but common) "UT" or
    /// "GMT+0" gets dropped otherwise.
    private static func normaliseZone(in raw: String) -> String {
        let replacements: [(String, String)] = [
            (" UT", " +0000"), (" GMT", " +0000"), (" UTC", " +0000"),
            (" Z", " +0000"), (" EST", " -0500"), (" EDT", " -0400"),
            (" CST", " -0600"), (" CDT", " -0500"), (" MST", " -0700"),
            (" MDT", " -0600"), (" PST", " -0800"), (" PDT", " -0700"),
        ]
        for (abbreviation, offset) in replacements where raw.hasSuffix(abbreviation) {
            return String(raw.dropLast(abbreviation.count)) + offset
        }
        return raw
    }
}

extension Date {

    /// "4m", "3h", "2d" — the compact form a scannable feed wants.
    ///
    /// Deliberately not `RelativeDateTimeFormatter`: "4 minutes ago" is three
    /// times the width for the same information, and in a wire list that width
    /// comes out of the headline.
    var feedAge: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 0 { return "now" }
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }

        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: self)
    }
}
