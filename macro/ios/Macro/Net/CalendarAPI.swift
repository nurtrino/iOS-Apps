import Foundation

/// Forex Factory's economic calendar.
///
/// FF publishes the calendar its widget runs on as plain JSON from a CDN, one
/// file per week, no key required — the same data as the site's calendar page:
/// title, currency, timestamp, impact, forecast and previous. There is no
/// "actual" column in the export; tapping through to the source is what the
/// news tab is for.
enum CalendarAPI {

    static let thisWeekURL = URL(string: "https://nfs.faireconomy.media/ff_calendar_thisweek.json")!
    static let nextWeekURL = URL(string: "https://nfs.faireconomy.media/ff_calendar_nextweek.json")!

    private struct DTO: Decodable {
        let title: String
        let country: String
        /// ISO 8601 with a numeric offset, e.g. "2026-08-25T08:30:00-04:00".
        let date: String
        let impact: String
        let forecast: String?
        let previous: String?
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Both weeks, merged and sorted. This week is required; next week is a
    /// bonus — FF publishes it late on some weekends and the calendar should
    /// not fail outright while it is missing.
    static func fetchAll() async throws -> [EconEvent] {
        let thisWeek = try await fetchWeek(from: thisWeekURL)
        let nextWeek = (try? await fetchWeek(from: nextWeekURL)) ?? []

        var seen = Set<String>()
        var merged: [EconEvent] = []
        for event in thisWeek + nextWeek where seen.insert(event.id).inserted {
            merged.append(event)
        }
        return merged.sorted { $0.date < $1.date }
    }

    static func fetchWeek(from url: URL) async throws -> [EconEvent] {
        let rows = try await HTTP.shared.json([DTO].self, from: url)

        let events = rows.compactMap { row -> EconEvent? in
            guard let date = iso.date(from: row.date) else { return nil }
            return EconEvent(
                id: row.country + "|" + row.title + "|" + row.date,
                title: row.title,
                currency: row.country,
                date: date,
                impact: Impact(label: row.impact),
                forecast: normalised(row.forecast),
                previous: normalised(row.previous)
            )
        }
        guard !events.isEmpty else { throw FeedError.empty }
        return events
    }

    private static func normalised(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
