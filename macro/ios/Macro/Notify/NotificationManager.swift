import Foundation
import UserNotifications

/// All notification traffic, in one place.
///
/// Everything here is a *local* notification. Remote push (APNs) needs an
/// `aps-environment` entitlement baked into a signing profile, and this app
/// ships as an unsigned .ipa — whoever installs it signs it themselves, with
/// a profile that has no push entitlement. So the app notifies from what it
/// can know on-device: the calendar's own schedule, and whatever a background
/// fetch finds that is new. That covers the two things worth being tapped on
/// the shoulder for — "CPI in 15 minutes" and "ZeroHedge just published".
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    private static let eventPrefix = "event-"
    private static let newsPrefix = "news-"

    /// iOS keeps at most 64 pending local notifications per app; the rest are
    /// silently discarded, newest first — so the app stays under the cap and
    /// chooses which ones matter (the soonest) itself.
    private static let maxScheduled = 48

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Calendar event reminders

    /// Replans every event reminder from the given calendar.
    ///
    /// Wholesale replace rather than incremental update: FF revises times
    /// during the week, and diffing revisions against pending requests is
    /// more code than removing and re-adding forty of them.
    func rescheduleEventReminders(events: [EconEvent], settings: SettingsSnapshot) {
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.eventPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)

            let wanted = settings.eventAlertLevel.impacts
            guard !wanted.isEmpty else { return }

            let lead = TimeInterval(max(0, settings.eventLeadMinutes) * 60)
            var scheduled = 0

            for event in events.sorted(by: { $0.date < $1.date }) {
                guard scheduled < Self.maxScheduled else { break }
                guard wanted.contains(event.impact) else { continue }
                if !settings.alertCurrenciesOnly.isEmpty,
                   !settings.alertCurrenciesOnly.contains(event.currency) {
                    continue
                }

                let fireDate = event.date.addingTimeInterval(-lead)
                // Less than a minute out there is nothing useful left to say.
                guard fireDate.timeIntervalSinceNow > 60 else { continue }

                let content = UNMutableNotificationContent()
                content.title = "\(event.currency) · \(event.title)"
                var lines: [String] = []
                if settings.eventLeadMinutes > 0 {
                    lines.append("In \(settings.eventLeadMinutes) min · \(event.impact.label) impact")
                } else {
                    lines.append("Now · \(event.impact.label) impact")
                }
                if let forecast = event.forecast { lines.append("Forecast \(forecast)") }
                if let previous = event.previous { lines.append("Previous \(previous)") }
                content.body = lines.joined(separator: "  ·  ")
                content.sound = .default

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

                center.add(UNNotificationRequest(
                    identifier: Self.eventPrefix + event.id,
                    content: content,
                    trigger: trigger))
                scheduled += 1
            }
        }
    }

    // MARK: - Breaking headlines

    /// Posts immediate notifications for freshly arrived stories.
    ///
    /// Capped hard: a background fetch that finds thirty new items posts the
    /// three newest and stays quiet about the rest. Thirty banners is how an
    /// app gets its notification permission revoked.
    func postHeadlines(_ articles: [Article]) {
        let center = UNUserNotificationCenter.current()
        for article in articles.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = article.sourceName
            content.body = article.title
            content.sound = .default

            center.add(UNNotificationRequest(
                identifier: Self.newsPrefix + StableHash.hex(article.id),
                content: content,
                trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners show even while the app is frontmost — a high-impact release
    /// firing in fifteen minutes is worth a banner over whatever tab is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
