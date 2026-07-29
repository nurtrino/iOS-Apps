import SwiftUI

/// An unofficial, read-only reader for 4chan's /pol/.
///
/// Read-only is a property of the API, not a product choice made late: 4chan
/// publishes no write endpoint, so there is no posting, voting or replying to
/// build. Anything that needs an account links out to the website.
@main
@MainActor
struct PolReaderApp: App {

    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var filters = FilterStore.shared
    /// Kept alive for the whole app lifetime so switching tabs preserves the
    /// catalog and its scroll position instead of refetching a board that
    /// turns over fast enough to look completely different a minute later.
    @StateObject private var catalog = CatalogStore(board: "pol")

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(filters)
                .environmentObject(catalog)
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .onChange(of: scenePhase) { phase in
            // Debounced writes would otherwise be lost on the way out.
            if phase != .active {
                library.flush()
                filters.flush()
            }
        }
    }
}
