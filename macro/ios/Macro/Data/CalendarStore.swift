import Foundation

/// The economic calendar, and the reminders scheduled off it.
@MainActor
final class CalendarStore: ObservableObject {

    enum Phase {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var events: [EconEvent] = []
    @Published private(set) var lastRefreshed: Date?

    private var isRefreshing = false

    /// The currencies actually present, for the filter chips.
    var currencies: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for event in events where seen.insert(event.currency).inserted {
            ordered.append(event.currency)
        }
        return ordered.sorted()
    }

    func refreshIfStale(settings: SettingsSnapshot) async {
        if let last = lastRefreshed, Date().timeIntervalSince(last) < 15 * 60,
           !events.isEmpty {
            return
        }
        await refresh(settings: settings)
    }

    func refresh(settings: SettingsSnapshot) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if events.isEmpty { phase = .loading }

        do {
            let fetched = try await CalendarAPI.fetchAll()
            events = fetched
            lastRefreshed = Date()
            phase = .loaded

            // The calendar is the schedule the reminders come from, so every
            // successful load re-plans them against the freshest dates.
            NotificationManager.shared.rescheduleEventReminders(
                events: fetched, settings: settings)
        } catch {
            if events.isEmpty {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
