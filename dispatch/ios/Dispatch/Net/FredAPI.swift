import Foundation

/// One published data point.
struct FredObservation: Equatable, Hashable {
    /// The period the number describes, not the day it was published.
    let date: Date
    let value: Double
}

/// What a series' numbers mean, which decides how they are written.
enum SeriesUnit {
    /// An index level — the level itself is meaningless to a reader, so the
    /// change is the story. CPI, PPI, PCE.
    case index
    /// Thousands of persons. Payrolls, where the monthly *change* is the number
    /// everyone quotes.
    case thousands
    /// Already a percentage. Unemployment rate, fed funds target.
    case percent
    /// A plain count. Initial claims.
    case count
    /// Millions of dollars. Retail sales, where the monthly percentage moves.
    case millionsOfDollars
}

/// How often a series prints, which is only used for labelling a period.
///
/// A monthly index's observation date is the first of the month, so printing it
/// as "Jun 1" would invent a precision the number does not have — it describes
/// June, not the first of June.
enum SeriesPeriod {
    case monthly
    case weekly
    case daily
}

/// A FRED series the calendar can show numbers for.
struct FredSeries: Identifiable, Hashable {
    /// The FRED series id, which doubles as the identity here.
    let id: String
    let title: String
    let unit: SeriesUnit
    var period: SeriesPeriod = .monthly
}

/// The release each calendar entry corresponds to.
///
/// An explicit kind rather than parsing the event id: the id carries a date so
/// it can be unique, and pulling "cpi" back out of "cpi-2026-7" would be a
/// parser where a stored property does.
enum EconEventKind: String {
    case claims
    case payrolls
    case ismManufacturing
    case ismServices
    case cpi
    case ppi
    case retailSales
    case pce
    case fomc

    /// The headline number for this release, and the one worth showing beside it.
    ///
    /// ISM has none, and that is not an oversight: FRED's ISM series were pulled
    /// for licensing reasons, so there is no free source for them. The sheet says
    /// so rather than showing an empty table.
    var series: [FredSeries] {
        switch self {
        case .claims:
            return [FredSeries(id: "ICSA", title: "Initial claims", unit: .count, period: .weekly)]
        case .payrolls:
            return [
                FredSeries(id: "PAYEMS", title: "Nonfarm payrolls", unit: .thousands),
                FredSeries(id: "UNRATE", title: "Unemployment rate", unit: .percent),
            ]
        case .cpi:
            return [
                FredSeries(id: "CPIAUCSL", title: "CPI", unit: .index),
                FredSeries(id: "CPILFESL", title: "Core CPI", unit: .index),
            ]
        case .ppi:
            return [FredSeries(id: "PPIFIS", title: "PPI, final demand", unit: .index)]
        case .retailSales:
            return [FredSeries(id: "RSAFS", title: "Retail sales", unit: .millionsOfDollars)]
        case .pce:
            return [
                FredSeries(id: "PCEPI", title: "PCE price index", unit: .index),
                FredSeries(id: "PCEPILFE", title: "Core PCE", unit: .index),
            ]
        case .fomc:
            return [FredSeries(id: "DFEDTARU", title: "Fed funds target, upper",
                               unit: .percent, period: .daily)]
        case .ismManufacturing, .ismServices:
            return []
        }
    }
}

/// The last few observations of a series, and what they add up to.
struct SeriesReading {
    let series: FredSeries
    /// Newest first.
    let observations: [FredObservation]

    var latest: FredObservation? { observations.first }
    var previous: FredObservation? { observations.count > 1 ? observations[1] : nil }

    /// The observation closest to a year before the latest one.
    ///
    /// Found by date rather than by counting twelve rows back, because the same
    /// code has to work for a weekly series and a monthly one.
    var yearAgo: FredObservation? {
        guard let latest else { return nil }
        guard let target = Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: -1, to: latest.date) else { return nil }
        return FredCSV.nearest(to: target, in: observations.dropFirst())
    }

    /// The big number at the top of the sheet.
    var headline: String {
        guard let latest else { return "—" }
        switch series.unit {
        case .index:
            guard let yearAgo, yearAgo.value != 0 else { return FredCSV.decimal(latest.value, places: 1) }
            return FredCSV.signedPercent(FredCSV.percentChange(latest.value, from: yearAgo.value))
        case .thousands:
            guard let previous else { return FredCSV.thousandsLevel(latest.value) }
            let change = (latest.value - previous.value) * 1000
            return FredCSV.signedCount(change)
        case .percent:
            return FredCSV.decimal(latest.value, places: latest.value < 10 ? 1 : 2) + "%"
        case .count:
            return FredCSV.count(latest.value)
        case .millionsOfDollars:
            guard let previous, previous.value != 0 else { return FredCSV.thousandsLevel(latest.value) }
            return FredCSV.signedPercent(FredCSV.percentChange(latest.value, from: previous.value))
        }
    }

    /// What the headline number *is*, since "+2.9%" alone does not say.
    var headlineCaption: String {
        switch series.unit {
        case .index: return "year over year"
        case .thousands: return "change on the month"
        case .percent: return "latest level"
        case .count: return "latest week"
        case .millionsOfDollars: return "change on the month"
        }
    }

    /// The second line: the other reading that gives the headline context.
    var detail: String? {
        guard let latest else { return nil }
        switch series.unit {
        case .index:
            guard let previous, previous.value != 0 else { return nil }
            return "Month over month "
                + FredCSV.signedPercent(FredCSV.percentChange(latest.value, from: previous.value))
        case .thousands:
            return "Level " + FredCSV.thousandsLevel(latest.value)
        case .percent:
            guard let previous else { return nil }
            let change = latest.value - previous.value
            if abs(change) < 0.001 { return "Unchanged from the previous reading" }
            return "Previous " + FredCSV.decimal(previous.value, places: 2) + "%"
        case .count:
            guard let previous else { return nil }
            let change = latest.value - previous.value
            return "Previous week " + FredCSV.count(previous.value)
                + " (" + FredCSV.signedCount(change) + ")"
        case .millionsOfDollars:
            guard let yearAgo, yearAgo.value != 0 else { return nil }
            return "Year over year "
                + FredCSV.signedPercent(FredCSV.percentChange(latest.value, from: yearAgo.value))
        }
    }

    /// How one row of the table reads.
    func row(for observation: FredObservation) -> String {
        switch series.unit {
        case .index: return FredCSV.decimal(observation.value, places: 1)
        case .thousands: return FredCSV.thousandsLevel(observation.value)
        case .percent: return FredCSV.decimal(observation.value, places: 2) + "%"
        case .count: return FredCSV.count(observation.value)
        case .millionsOfDollars: return FredCSV.thousandsLevel(observation.value)
        }
    }
}

/// Parsing and arithmetic for FRED's CSV. Mirrored in `tools/feed_reference.py`.
enum FredCSV {

    /// The date/value pairs of a fredgraph CSV, oldest first, skipping gaps.
    ///
    /// Three things about the format matter. The header's first column has been
    /// both `DATE` and `observation_date` depending on when you ask, so the
    /// header is skipped by *shape* — a row whose second field is not a number —
    /// rather than by name. A missing observation is a literal `.`, which parses
    /// as neither a number nor an error and has to be dropped. And the file is
    /// served with CRLF line endings often enough to matter.
    static func rows(_ text: String) -> [(String, Double)] {
        var out: [(String, Double)] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.replacingOccurrences(of: "\r", with: "")
                .split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let day = fields[0].trimmingCharacters(in: .whitespaces)
            let raw = fields[1].trimmingCharacters(in: .whitespaces)
            guard let value = Double(raw) else { continue }
            guard day.count == 10, day.first?.isNumber == true else { continue }
            out.append((day, value))
        }
        return out
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Newest first, which is the order everything downstream wants.
    static func observations(_ text: String) -> [FredObservation] {
        rows(text)
            .compactMap { day, value in
                guard let date = dayFormatter.date(from: day) else { return nil }
                return FredObservation(date: date, value: value)
            }
            .sorted { $0.date > $1.date }
    }

    static func nearest<C: Collection>(to target: Date, in observations: C) -> FredObservation?
    where C.Element == FredObservation {
        observations.min { left, right in
            abs(left.date.timeIntervalSince(target)) < abs(right.date.timeIntervalSince(target))
        }
    }

    // MARK: - Arithmetic and formatting

    static func percentChange(_ new: Double, from old: Double) -> Double {
        guard old != 0 else { return 0 }
        return (new / old - 1) * 100
    }

    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    static func signedPercent(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + decimal(value, places: 1) + "%"
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func count(_ value: Double) -> String {
        grouping.string(from: NSNumber(value: value.rounded())) ?? decimal(value, places: 0)
    }

    static func signedCount(_ value: Double) -> String {
        (value >= 0 ? "+" : "-") + count(abs(value))
    }

    /// A series held in thousands, printed as the real number.
    static func thousandsLevel(_ value: Double) -> String {
        count(value * 1000)
    }
}

/// Fetches series from FRED.
///
/// `fredgraph.csv` needs no key, which is the whole reason the calendar can show
/// real numbers at all — FRED's documented API requires one, and this app's rule
/// is that a feature cannot depend on the reader signing up for something. The
/// trade is that this is a convenience endpoint rather than a contract, so every
/// call is allowed to fail and the sheet says so plainly when it does.
actor FredAPI {

    static let shared = FredAPI()

    private struct Entry {
        let observations: [FredObservation]
        let fetched: Date
    }

    private var cache: [String: Entry] = [:]

    /// Numbers move once a month. An hour is short enough to catch a release and
    /// long enough that reopening the sheet is instant.
    private static let ttl: TimeInterval = 3600

    /// How much history to ask for. Enough for a year-over-year comparison plus
    /// a table, and small enough to be a few kilobytes.
    private static let years = 3

    func observations(for series: FredSeries) async throws -> [FredObservation] {
        if let cached = cache[series.id],
           Date().timeIntervalSince(cached.fetched) < FredAPI.ttl {
            return cached.observations
        }

        var components = URLComponents(string: "https://fred.stlouisfed.org/graph/fredgraph.csv")
        var items = [URLQueryItem(name: "id", value: series.id)]
        if let start = Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: -FredAPI.years, to: Date()) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            items.append(URLQueryItem(name: "cosd", value: formatter.string(from: start)))
        }
        components?.queryItems = items

        guard let url = components?.url else { throw FeedError.badURL(series.id) }

        let data = try await HTTP.shared.data(from: url, accept: "text/csv,text/plain,*/*")
        guard let text = String(data: data, encoding: .utf8) else { throw FeedError.notAFeed }

        let observations = FredCSV.observations(text)
        guard !observations.isEmpty else { throw FeedError.empty }

        cache[series.id] = Entry(observations: observations, fetched: Date())
        return observations
    }

    func reading(for series: FredSeries) async throws -> SeriesReading {
        SeriesReading(series: series, observations: try await observations(for: series))
    }
}
