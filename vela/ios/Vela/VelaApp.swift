import SwiftUI
import UIKit

/// A client for PeerTube, the open federated video network.
///
/// Every feature here is one the platform actually offers: PeerTube serves no
/// ads, exposes a download URL per video gated by the uploader's own
/// `downloadEnabled` flag, and publishes a documented API with real OAuth. So
/// offline downloads, background audio and Picture in Picture are just work,
/// not workarounds — which is also why they are likely to keep working.
@main
@MainActor
struct VelaApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings = SettingsStore.shared
    @StateObject private var auth = AuthStore.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var keys = APIKeyStatus.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(auth)
                .environmentObject(downloads)
                .environmentObject(player)
                .environmentObject(keys)
                .preferredColorScheme(settings.theme.colorScheme)
                .task {
                    // Concurrently: the YouTube key and the PeerTube session are
                    // unrelated, and serialising them delays whichever tab you
                    // happen to open first.
                    async let session: Void = auth.restore()
                    async let apiKey: Void = keys.restore()
                    _ = await (session, apiKey)
                }
        }
    }
}

/// Exists for one reason: background downloads.
///
/// When a transfer finishes while the app is suspended, iOS relaunches it in
/// the background and calls this. The handler must be stored and invoked once
/// every delivered file has been processed — failing to call it makes the
/// system consider the app unresponsive and stop waking it for future
/// transfers.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}
