import BackgroundTasks
import Foundation

/// Keeps the on-disk feed caches warm while the app is closed.
///
/// The work runs against *fresh* stores rather than the live ones the UI holds.
/// That is deliberate: a background launch may happen with no UI at all, and
/// reaching into `@StateObject`s that may or may not exist is the kind of thing
/// that works in the simulator and crashes on a phone. Everything this needs —
/// the source list, the settings, the Steam library — is on disk already, and
/// the only output is the same feed cache the foreground path writes, so the
/// next launch simply finds newer files.
enum BackgroundRefresh {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist. iOS
    /// silently refuses to schedule an identifier that is not listed there.
    static let identifier = "com.nurtrino.dispatch.refresh"

    /// Asks for another run. iOS decides if and when, based on how the app is
    /// actually used, so this is a request and never a guarantee.
    static func schedule(after interval: TimeInterval = 30 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        // Throws when running in a context that cannot schedule — the
        // simulator, or an app not yet permitted. Not worth surfacing.
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func run() async {
        let settings = SettingsStore()
        let catalog = CatalogStore()
        let library = SteamLibraryStore()
        let feed = FeedStore()

        feed.hydrateFromCache(sources: catalog.sources)

        // Filing with Claude is left off here on purpose. A background wake
        // spending money on the API with nobody looking is a surprise on a bill;
        // the fetch is the useful part, and the first foreground refresh files
        // whatever arrived.
        var environment = settings.loadEnvironment(games: library.activeGames)
        environment.sortsWithModel = false

        await feed.refresh(
            sources: catalog.enabledSources,
            environment: environment,
            force: true
        )
    }
}
