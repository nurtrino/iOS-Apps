import Foundation

/// How well the app actually knows when something happens.
///
/// This distinction is the whole reason the calendar is honest enough to ship.
/// Some releases follow a rule that never moves — jobless claims are every
/// Thursday, ISM Manufacturing is the first business day — and those dates are
/// right. Others land "somewhere in the second week", and pretending otherwise
/// would put a confident wrong date in front of someone making a decision.
enum EventPrecision: String, Codable {
    /// Published by the agency, or fixed by a rule that does not vary.
    case confirmed
    /// Derived from the usual pattern. Shown with a "~" and a caveat.
    case approximate
}

enum EventImportance: Int, Codable, Comparable {
    case routine = 0
    case notable = 1
    case major = 2

    static func < (lhs: EventImportance, rhs: EventImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct EconEvent: Identifiable, Hashable {
    let id: String
    /// Which release this is, so the detail sheet knows which numbers to pull.
    let kind: EconEventKind
    let title: String
    let agency: String
    let date: Date
    let precision: EventPrecision
    let importance: EventImportance

    /// Whether there are published numbers behind it — see `EconEventKind`.
    var hasNumbers: Bool { !kind.series.isEmpty }

    var isToday: Bool {
        Calendar.autoupdatingCurrent.isDateInToday(date)
    }

    var isPast: Bool { date < Date() }
}

/// The US release calendar, generated on device.
///
/// There is no free economic calendar API worth depending on — the ones that
/// exist need a key, rate-limit hard, or are a scrape of somebody's web page
/// that breaks monthly. But most of what matters is a *rule*, not a feed:
/// jobless claims every Thursday at 8:30, payrolls the first Friday, ISM on the
/// first business day. Those can be generated exactly, offline, forever.
///
/// The two things that are not rules are handled explicitly: FOMC dates come
/// from the Fed's published schedule, shipped as a table, and the releases that
/// genuinely drift — CPI, PPI — are marked approximate so the screen can say so.
enum EconCalendar {

    /// Eastern time. Every US release time is quoted in it, and it moves with
    /// daylight saving, so an offset would be wrong for half the year.
    private static var eastern: TimeZone {
        TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        return calendar
    }

    /// FOMC decision days — the second day of each meeting, when the statement
    /// lands at 14:00 ET.
    ///
    /// From the Federal Reserve's published 2026 schedule. **This table needs
    /// extending each year**; `precheck.py` fails once it is close to running
    /// out, so it cannot quietly go stale and leave the calendar with no Fed
    /// dates in it.
    static let fomcDecisionDays: [DateComponents] = [
        DateComponents(year: 2026, month: 1, day: 28),
        DateComponents(year: 2026, month: 3, day: 18),
        DateComponents(year: 2026, month: 4, day: 29),
        DateComponents(year: 2026, month: 6, day: 17),
        DateComponents(year: 2026, month: 7, day: 29),
        DateComponents(year: 2026, month: 9, day: 16),
        DateComponents(year: 2026, month: 10, day: 28),
        DateComponents(year: 2026, month: 12, day: 9),
    ]

    /// Every event between two dates, in order.
    static func events(from start: Date, to end: Date) -> [EconEvent] {
        var events: [EconEvent] = []

        events += weeklyClaims(from: start, to: end)
        events += monthlyReleases(from: start, to: end)
        events += fomc(from: start, to: end)

        return events
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }
    }

    /// The next handful, for the strip at the top of the Markets screen.
    static func upcoming(limit: Int = 8, from now: Date = Date()) -> [EconEvent] {
        let calendar = self.calendar
        // Back to the start of today so a release that already happened this
        // morning still shows — "CPI came in at 8:30" is the most relevant
        // thing on the screen at 9am.
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 45, to: now) ?? now
        return Array(events(from: start, to: end).prefix(limit))
    }

    // MARK: - Generators

    private static func at(_ date: Date, hour: Int, minute: Int) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// Initial jobless claims: every Thursday, 8:30 ET. No exceptions worth
    /// modelling — a holiday shifts the *collection* week, not the release.
    private static func weeklyClaims(from start: Date, to end: Date) -> [EconEvent] {
        let calendar = self.calendar
        var events: [EconEvent] = []
        var cursor = calendar.startOfDay(for: start)

        while cursor <= end {
            if calendar.component(.weekday, from: cursor) == 5, // Thursday
               let date = at(cursor, hour: 8, minute: 30) {
                events.append(EconEvent(
                    id: "claims-\(Int(date.timeIntervalSince1970))",
                    kind: .claims,
                    title: "Initial Jobless Claims",
                    agency: "DOL",
                    date: date,
                    precision: .confirmed,
                    importance: .routine
                ))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return events
    }

    private static func fomc(from start: Date, to end: Date) -> [EconEvent] {
        fomcDecisionDays.compactMap { components in
            var components = components
            components.hour = 14
            components.minute = 0
            guard let date = calendar.date(from: components) else { return nil }
            return EconEvent(
                id: "fomc-\(Int(date.timeIntervalSince1970))",
                kind: .fomc,
                title: "FOMC Rate Decision",
                agency: "Federal Reserve",
                date: date,
                precision: .confirmed,
                importance: .major
            )
        }
    }

    /// The monthly releases, each from its own rule.
    private static func monthlyReleases(from start: Date, to end: Date) -> [EconEvent] {
        let calendar = self.calendar
        var events: [EconEvent] = []

        // Walk month by month, one either side of the window so a release
        // near a boundary is not lost.
        guard var cursor = calendar.date(byAdding: .month, value: -1,
                                         to: calendar.startOfDay(for: start)) else { return [] }

        while cursor <= end {
            let year = calendar.component(.year, from: cursor)
            let month = calendar.component(.month, from: cursor)

            if let payrolls = nthWeekday(6, ordinal: 1, month: month, year: year),
               let date = at(payrolls, hour: 8, minute: 30) {
                events.append(EconEvent(
                    id: "nfp-\(year)-\(month)",
                    kind: .payrolls,
                    title: "Nonfarm Payrolls",
                    agency: "BLS",
                    date: date,
                    precision: .confirmed,
                    importance: .major
                ))
            }

            if let ismDay = nthBusinessDay(1, month: month, year: year),
               let date = at(ismDay, hour: 10, minute: 0) {
                events.append(EconEvent(
                    id: "ism-mfg-\(year)-\(month)",
                    kind: .ismManufacturing,
                    title: "ISM Manufacturing PMI",
                    agency: "ISM",
                    date: date,
                    precision: .confirmed,
                    importance: .notable
                ))
            }

            if let ismDay = nthBusinessDay(3, month: month, year: year),
               let date = at(ismDay, hour: 10, minute: 0) {
                events.append(EconEvent(
                    id: "ism-svc-\(year)-\(month)",
                    kind: .ismServices,
                    title: "ISM Services PMI",
                    agency: "ISM",
                    date: date,
                    precision: .confirmed,
                    importance: .notable
                ))
            }

            // CPI lands between the 10th and the 15th depending on the month,
            // so this is the middle of that range and is labelled as a guess.
            if let day = dayOf(12, month: month, year: year),
               let date = at(businessDayOnOrAfter(day), hour: 8, minute: 30) {
                events.append(EconEvent(
                    id: "cpi-\(year)-\(month)",
                    kind: .cpi,
                    title: "Consumer Price Index",
                    agency: "BLS",
                    date: date,
                    precision: .approximate,
                    importance: .major
                ))
            }

            if let day = dayOf(14, month: month, year: year),
               let date = at(businessDayOnOrAfter(day), hour: 8, minute: 30) {
                events.append(EconEvent(
                    id: "ppi-\(year)-\(month)",
                    kind: .ppi,
                    title: "Producer Price Index",
                    agency: "BLS",
                    date: date,
                    precision: .approximate,
                    importance: .notable
                ))
            }

            if let day = dayOf(16, month: month, year: year),
               let date = at(businessDayOnOrAfter(day), hour: 8, minute: 30) {
                events.append(EconEvent(
                    id: "retail-\(year)-\(month)",
                    kind: .retailSales,
                    title: "Retail Sales",
                    agency: "Census",
                    date: date,
                    precision: .approximate,
                    importance: .notable
                ))
            }

            if let day = dayOf(27, month: month, year: year),
               let date = at(businessDayOnOrAfter(day), hour: 8, minute: 30) {
                events.append(EconEvent(
                    id: "pce-\(year)-\(month)",
                    kind: .pce,
                    title: "PCE Price Index",
                    agency: "BEA",
                    date: date,
                    precision: .approximate,
                    importance: .major
                ))
            }

            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return events
    }

    // MARK: - Date arithmetic

    private static func dayOf(_ day: Int, month: Int, year: Int) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The nth occurrence of a weekday in a month. `weekday` uses `Calendar`
    /// numbering, so 6 is Friday.
    private static func nthWeekday(_ weekday: Int, ordinal: Int, month: Int, year: Int) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month,
                                           weekday: weekday, weekdayOrdinal: ordinal))
    }

    private static func isBusinessDay(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // Weekends only. Federal holidays are not modelled — doing it properly
        // means Juneteenth, floating Mondays and Good Friday for the markets
        // but not the agencies, and being one day out on three releases a year
        // is a better trade than that table quietly rotting.
        return weekday != 1 && weekday != 7
    }

    private static func businessDayOnOrAfter(_ date: Date) -> Date {
        var cursor = date
        var guard_ = 0
        while !isBusinessDay(cursor), guard_ < 7 {
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            guard_ += 1
        }
        return cursor
    }

    private static func nthBusinessDay(_ n: Int, month: Int, year: Int) -> Date? {
        guard var cursor = dayOf(1, month: month, year: year) else { return nil }
        var counted = 0
        for _ in 0..<20 {
            if isBusinessDay(cursor) {
                counted += 1
                if counted == n { return cursor }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }
}
