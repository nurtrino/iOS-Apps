import SwiftUI
import UserNotifications

@main
struct MacroApp: App {

    // The stores are created here and only here. Everything below reads them
    // from the environment, so there is exactly one feed, one calendar and one
    // read-state list for the whole app.
    @StateObject private var settings = SettingsStore()
    @StateObject private var news = NewsStore()
    @StateObject private var calendar = CalendarStore()
    @StateObject private var market = MarketStore()
    @StateObject private var articleState = ArticleStateStore()

    init() {
        // Claimed before anything can fire, so reminders show as banners even
        // while the app is frontmost.
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(news)
                .environmentObject(calendar)
                .environmentObject(market)
                .environmentObject(articleState)
                .onAppear { BackgroundRefresh.schedule() }
        }
        // Registers the handler and the task identifier in one place. The
        // UIKit equivalent needs `BGTaskScheduler.register` to run before
        // `didFinishLaunching` returns, which is easy to get subtly wrong; this
        // modifier does it for us.
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
            // Re-arm from inside the run, because a task only ever gets one
            // scheduled occurrence — forgetting this is why background refresh
            // "works once and then stops".
            await MainActor.run { BackgroundRefresh.schedule() }
        }
    }
}
