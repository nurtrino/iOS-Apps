import BackgroundTasks
import Foundation

/// Wakes up while the app is closed, so the notifications stay honest.
///
/// The event reminders are scheduled ahead of time and fire on their own, but
/// they drift stale as Forex Factory revises its times — and breaking-news
/// alerts cannot exist at all without someone fetching the feeds. Both are
/// this task's job. It runs against plain functions and UserDefaults, never
/// the UI's stores: a background launch may happen with no UI at all.
enum BackgroundRefresh {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist — iOS
    /// silently refuses to schedule an identifier that is not listed there —
    /// and the `.backgroundTask(.appRefresh(...))` registration in `MacroApp`.
    static let identifier = "com.nurtrino.macro.refresh"

    /// Asks for another run. iOS decides if and when, based on how the app is
    /// actually used, so this is a request and never a guarantee.
    static func schedule(after interval: TimeInterval = 30 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        // Throws when running in a context that cannot schedule — the
        // simulator, or an app not yet permitted. Not worth surfacing.
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        let settings = SettingsSnapshot.load()

        // Refresh the calendar and re-plan reminders against revised times.
        if settings.eventAlertLevel != .off,
           let events = try? await CalendarAPI.fetchAll() {
            NotificationManager.shared.rescheduleEventReminders(
                events: events, settings: settings)
        }

        guard settings.headlineAlerts else { return }

        // First run ever: record what exists and say nothing. Announcing an
        // entire feed as "breaking" once would be the app's last notification.
        let establishBaseline = !SeenStore.hasBaseline

        let sources = FeedCatalog.sources.filter { settings.enabledSources.contains($0.id) }
        var fresh: [Article] = []

        for source in sources {
            guard !Task.isCancelled else { return }
            guard let articles = try? await FeedAPI.fetch(source) else { continue }
            fresh += SeenStore.unseen(from: articles)
        }

        guard !fresh.isEmpty else { return }
        SeenStore.merge(fresh.map { $0.id })

        guard !establishBaseline else { return }
        NotificationManager.shared.postHeadlines(
            fresh.sorted { $0.sortDate > $1.sortDate })
    }
}
