import SwiftUI

@main
struct DispatchApp: App {

    // The stores are created here and only here. Everything below reads them
    // from the environment, so there is exactly one catalog, one feed cache and
    // one read-state list for the whole app — the alternative, letting screens
    // construct their own, is how two views end up disagreeing about what has
    // been read.
    @StateObject private var settings = SettingsStore()
    @StateObject private var catalog = CatalogStore()
    @StateObject private var feed = FeedStore()
    @StateObject private var read = ReadStore()
    @StateObject private var steamLibrary = SteamLibraryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(catalog)
                .environmentObject(feed)
                .environmentObject(read)
                .environmentObject(steamLibrary)
                .preferredColorScheme(settings.theme.colorScheme)
                .tint(Palette.accent)
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
