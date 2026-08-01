import AVKit
import SwiftUI
import UIKit
import WebKit

/// Plays a file the source handed us directly.
///
/// Telegram serves video posts as a plain MP4 on its CDN — no signing, no
/// token — so a video post can play in place. That matters because for a video
/// post the video *is* the post: opening the web page instead was throwing the
/// content away and showing a caption.
struct VideoSheet: View {

    let article: Article
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let url = article.videoURL {
                    VideoPlayer(player: AVPlayer(url: url))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                } else {
                    StateView(systemImage: "play.slash", title: "No video")
                }

                ScrollView {
                    Text(article.summary)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            }
            .navigationTitle(article.context ?? "Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A YouTube video or livestream, playing inside the app. Never Safari.
///
/// The naive embed fails often on iOS, and the failure was misread. YouTube's
/// error 150/153 is usually not "the owner disabled embedding" — it is
/// "embedder identity missing referrer": WKWebView does not send a `Referer`
/// for a cross-origin iframe, so YouTube cannot verify who is embedding and
/// refuses. That is a configuration bug, not a wall, and three things fix the
/// bulk of it: a `<meta name="referrer">` policy on the page, an `origin`
/// player var, and a real mobile-Safari user agent. The old player had none of
/// them.
///
/// When the embed still refuses — a genuinely embedding-disabled or
/// age-restricted video — the fallback is **not** a web browser. It loads
/// YouTube's own watch page into the same WKWebView. That page is the real
/// site, not an embed, so the embed flag does not apply and it plays; it is
/// still inside the app. Nothing here ever leaves for Safari.
struct YouTubePlayer: UIViewRepresentable {

    let videoID: String
    /// Optional, for telemetry only. The player recovers on its own; a caller
    /// no longer needs to offer Safari, because there is no case where it gives
    /// up to the browser.
    var onFailure: () -> Void = {}

    // A current iPhone Safari UA. Sent so YouTube serves the real mobile player
    // rather than a degraded page — the default WKWebView UA is one of the
    // things that trips the "unverified embedder" refusal.
    static let mobileSafariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the embed hands to the system fullscreen player the
        // instant it starts, dropping it out of the sheet.
        configuration.allowsInlineMediaPlayback = true
        // A video someone tapped is an explicit request to play.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "player")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = YouTubePlayer.mobileSafariUA
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        context.coordinator.videoID = videoID

        // `updateUIView` runs on every parent state change; reloading each time
        // restarts the stream whenever the surrounding view redraws.
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        context.coordinator.usedFallback = false
        webView.loadHTMLString(YouTubePlayer.page(for: videoID),
                               baseURL: URL(string: "https://www.youtube.com"))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // The controller retains the handler which retains the coordinator —
        // without this the whole chain leaks per playback.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "player")
    }

    /// The watch page, loaded as a real navigation when the embed is refused.
    static func watchURL(for videoID: String) -> URL? {
        URL(string: "https://m.youtube.com/watch?v=\(videoID)")
    }

    /// The IFrame API in a page whose origin is youtube.com, with the referrer
    /// and origin plumbing YouTube now requires.
    static func page(for videoID: String) -> String {
        let safeID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, \
        maximum-scale=1, user-scalable=no">
        <!-- The single most-cited fix for error 153: without a referrer policy
             WKWebView sends no Referer for the iframe and YouTube refuses. -->
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
        #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        function report(message) {
          try { window.webkit.messageHandlers.player.postMessage(message); } catch (e) {}
        }
        function onYouTubeIframeAPIReady() {
          new YT.Player('player', {
            videoId: '\(safeID)',
            host: 'https://www.youtube.com',
            playerVars: {
              playsinline: 1, autoplay: 1, rel: 0, modestbranding: 1, fs: 1,
              // Naming the origin is half of what makes YouTube trust the
              // embedder; the referrer meta tag is the other half.
              origin: 'https://www.youtube.com',
              enablejsapi: 1,
              widget_referrer: 'https://www.youtube.com'
            },
            events: {
              onReady: function (event) { event.target.playVideo(); report('ready'); },
              onError: function (event) { report('error:' + event.data); }
            }
          });
        }
        // If the API script itself is blocked the callback never fires; a silent
        // black rectangle is exactly what this is meant to avoid.
        setTimeout(function () { if (!window.YT || !window.YT.Player) report('error:timeout'); }, 6000);
        </script>
        </body>
        </html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

        var loadedVideoID: String?
        var videoID: String = ""
        var onFailure: () -> Void = {}
        weak var webView: WKWebView?
        /// Set once the watch-page fallback has been loaded, so a second error
        /// from that page does not loop back into it.
        var usedFallback = false

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String, body.hasPrefix("error:") else { return }
            // Every error code here — 101/150 (embedding disabled), 153
            // (referrer), 100 (removed), 5 (HTML5), timeout — means the *embed*
            // will not play. The answer to all of them is the same: load the
            // real watch page, in this same web view. Not Safari.
            fallBackToWatchPage()
        }

        private func fallBackToWatchPage() {
            guard !usedFallback, let webView,
                  let url = YouTubePlayer.watchURL(for: videoID) else { return }
            usedFallback = true
            Task { @MainActor in
                self.onFailure()
                var request = URLRequest(url: url)
                // A top-level https navigation *does* honour an explicit Referer
                // (the custom-scheme caveat does not apply here), which is what
                // gets the real player to load rather than a "confirm you're not
                // a robot" wall.
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
                webView.load(request)
            }
        }
    }
}

/// One tapped video post, ready to play.
struct EmbedPlayback: Identifiable {
    let id = UUID()
    let embed: VideoEmbed
    let title: String
}

/// Sends a tapped video where it plays best.
///
/// For YouTube that is the YouTube app: the real player, with the account, the
/// resolution picker and none of the embed-refusal dance. The in-app sheet
/// remains the fallback for a phone without the app — `open` on the `youtube://`
/// scheme simply reports failure when nothing handles it, and no
/// `LSApplicationQueriesSchemes` entry is needed because nothing here asks
/// `canOpenURL` first. Direct files have no app to defer to and always play in
/// the sheet.
enum VideoLauncher {

    @MainActor
    static func openInYouTubeApp(_ embed: VideoEmbed) async -> Bool {
        guard let id = embed.youtubeID else { return false }
        return await openVideo(id: id)
    }

    /// Opens a video id in the YouTube app, falling back to the watch page.
    ///
    /// The `youtube://` scheme is what forces the app rather than a browser.
    /// When the app is not installed `open` reports false, and the https watch
    /// page — a universal link — is tried next, which opens the app if it is
    /// there after all and Safari if it is not.
    @MainActor
    static func openVideo(id: String) async -> Bool {
        if let appURL = URL(string: "youtube://watch?v=\(id)"),
           await UIApplication.shared.open(appURL) {
            return true
        }
        guard let webURL = URL(string: "https://www.youtube.com/watch?v=\(id)") else { return false }
        return await UIApplication.shared.open(webURL)
    }

    /// Opens a channel's live tab in the YouTube app.
    ///
    /// Used when nothing is confirmed live yet: `…/@handle/live` lands on the
    /// current stream when there is one and the channel's live tab when there is
    /// not. Opened as a universal link so the YouTube app takes it if installed.
    @MainActor
    static func openChannelLive(reference: String) async -> Bool {
        guard let webURL = YouTubeLive.liveURL(reference: reference) else { return false }
        return await UIApplication.shared.open(webURL)
    }
}

/// Plays the video a post is about, whatever hosts it.
///
/// This is what a tap on a video post opens instead of Safari. Half of what a
/// link wire posts *is* a video — the page around it is a consent banner, a
/// cookie wall and comments — so the app plays the video and skips the page.
/// YouTube goes through `YouTubePlayer`, which recovers to the real watch page
/// in-app if the embed is refused; a direct file gets AVPlayer. Neither leaves
/// for Safari.
struct VideoEmbedSheet: View {

    let playback: EmbedPlayback

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                player

                Text(playback.title)
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)

                Spacer(minLength: 0)
            }
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        if let fileURL = playback.embed.fileURL {
            VideoPlayer(player: AVPlayer(url: fileURL))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        } else if let videoID = playback.embed.youtubeID {
            YouTubePlayer(videoID: videoID)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        } else {
            StateView(systemImage: "play.slash", title: "No playable video")
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
        }
    }
}

/// A live channel, playing in the app.
///
/// The stream plays through `YouTubePlayer`, which handles the embed and
/// recovers to YouTube's real watch page in the same web view if the embed is
/// refused — so a live channel that disables embedding still plays here rather
/// than kicking out to a browser.
struct LivePlayerSheet: View {

    let channel: LiveChannel
    let state: LiveState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                player
                details
                Spacer(minLength: 0)
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        if let videoID = state.videoID {
            YouTubePlayer(videoID: videoID)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "play.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Nothing playing.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = state.title {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.red)
                Text(channel.blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
