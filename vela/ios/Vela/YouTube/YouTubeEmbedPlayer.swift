import SwiftUI
import WebKit

/// Playback state reported back from the embedded player.
enum EmbedPlaybackState: Int {
    case unstarted = -1
    case ended = 0
    case playing = 1
    case paused = 2
    case buffering = 3
    case cued = 5
}

/// Drives one embedded YouTube player.
///
/// Separate from `PlayerEngine`, which owns the `AVPlayer` used by sources that
/// hand out a real file. The two cannot be merged: this one has no media to
/// hold, only a web view running YouTube's player, and everything `PlayerEngine`
/// exists to do — Picture in Picture, lock-screen controls, playing with the
/// screen off — is unavailable through the embed by design.
@MainActor
final class YouTubeEmbedController: ObservableObject {

    @Published private(set) var state: EmbedPlaybackState = .unstarted
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// The embed refuses some videos outright — the uploader can disable
    /// embedding, and rights holders can restrict it by region. There is no way
    /// to detect that before loading, so the error arrives here.
    @Published private(set) var embedRefused = false

    fileprivate weak var webView: WKWebView?

    var isPlaying: Bool { state == .playing || state == .buffering }

    func play() { evaluate("player.playVideo()") }
    func pause() { evaluate("player.pauseVideo()") }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        evaluate("player.seekTo(\(max(0, seconds)), true)")
        currentTime = seconds
    }

    func skip(by delta: Double) {
        seek(to: min(max(0, currentTime + delta), duration > 0 ? duration : .greatestFiniteMagnitude))
    }

    /// Called when the view goes away. Stopping explicitly matters: a web view
    /// torn down mid-playback can leave audio running until it is collected.
    func stop() {
        evaluate("player.stopVideo()")
        state = .unstarted
    }

    private func evaluate(_ script: String) {
        // Guarded on the JS side because a call landing before onReady throws,
        // and a thrown exception in a message handler is silent.
        webView?.evaluateJavaScript("if (window.player && player.playVideo) { \(script) }")
    }

    fileprivate func apply(_ message: [String: Any]) {
        switch message["event"] as? String {
        case "state":
            if let raw = message["state"] as? Int, let parsed = EmbedPlaybackState(rawValue: raw) {
                state = parsed
            }
        case "time":
            if let time = message["time"] as? Double { currentTime = time }
            if let total = message["duration"] as? Double, total > 0 { duration = total }
        case "error":
            // 101 and 150 are both "the uploader disallowed embedding". 100 is
            // a removed video, 2 a malformed id.
            embedRefused = true
        case "ready":
            embedRefused = false
        default:
            break
        }
    }
}

/// The web view hosting YouTube's IFrame player.
///
/// This is the sanctioned way to play a YouTube video inside another app: the
/// player is theirs, it reports its own state back over a bridge, and ads are
/// served by it. There is no supported path that yields the underlying media,
/// which is why this is a web view and not an `AVPlayer`.
struct YouTubeEmbedView: UIViewRepresentable {

    let videoID: String
    @ObservedObject var controller: YouTubeEmbedController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the player takes over the whole screen the moment it
        // starts, which defeats having designed a page around it.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controllerBridge = WKUserContentController()
        // A weak proxy: the content controller retains its handlers, and
        // handing it the coordinator directly leaks the web view with it.
        controllerBridge.add(WeakMessageProxy(context.coordinator), name: "vela")
        configuration.userContentController = controllerBridge

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        controller.webView = webView
        context.coordinator.load(videoID: videoID, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reloading the whole document for a new video rather than calling
        // loadVideoById: a fresh document is the only reliable way to clear the
        // previous video's error state.
        context.coordinator.load(videoID: videoID, into: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "vela")
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {

        private let controller: YouTubeEmbedController
        private var loadedVideoID: String?

        init(controller: YouTubeEmbedController) {
            self.controller = controller
        }

        func load(videoID: String, into webView: WKWebView) {
            guard videoID != loadedVideoID else { return }
            loadedVideoID = videoID
            // The base URL matters: the IFrame API checks the embedding origin,
            // and a document loaded with no origin is refused by some videos.
            webView.loadHTMLString(
                Self.document(videoID: videoID),
                baseURL: URL(string: "https://www.youtube.com")
            )
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let target = self.controller
            Task { @MainActor in target.apply(body) }
        }

        /// The page around YouTube's player.
        ///
        /// `playsinline=1` keeps it in the layout on iPhone. The polling timer
        /// is how position is reported: the IFrame API fires state changes but
        /// has no continuous time callback, so a scrubber needs this.
        private static func document(videoID: String) -> String {
            """
            <!doctype html>
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1, \
            maximum-scale=1, user-scalable=no">
            <style>
              html, body { margin: 0; padding: 0; background: #000; height: 100%; \
            overflow: hidden; }
              #player { width: 100%; height: 100%; }
            </style>
            </head>
            <body>
            <div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
              var player;
              var ticker;
              function send(payload) {
                window.webkit.messageHandlers.vela.postMessage(payload);
              }
              function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {
                  videoId: '\(videoID)',
                  playerVars: {
                    playsinline: 1, rel: 0, modestbranding: 1, controls: 1
                  },
                  events: {
                    onReady: function () {
                      send({ event: 'ready' });
                      clearInterval(ticker);
                      ticker = setInterval(function () {
                        if (!player || !player.getCurrentTime) return;
                        send({
                          event: 'time',
                          time: player.getCurrentTime(),
                          duration: player.getDuration()
                        });
                      }, 500);
                    },
                    onStateChange: function (e) {
                      send({ event: 'state', state: e.data });
                    },
                    onError: function (e) {
                      send({ event: 'error', code: e.data });
                    }
                  }
                });
              }
            </script>
            </body>
            </html>
            """
        }
    }
}

/// Breaks the retain cycle `WKUserContentController` would otherwise create by
/// holding its message handlers strongly.
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {

    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
