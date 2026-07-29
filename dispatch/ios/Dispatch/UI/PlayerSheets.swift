import AVKit
import SwiftUI
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

/// YouTube's official embed, with the one failure it has reported back.
///
/// The embed is the right way to play a YouTube video in an app — the media
/// URLs are signed and explicitly not for third-party players — but it has a
/// failure mode no amount of plumbing avoids: **a channel can switch embedding
/// off**, and YouTube then refuses with "Playback on other websites has been
/// disabled by the video owner". Channels living on ad revenue often do.
///
/// So this uses the IFrame Player API rather than a bare iframe, purely so the
/// `onError` callback can be heard. Codes 101 and 150 both mean "not
/// embeddable", and the sheet turns that into an honest offer of Safari instead
/// of a black rectangle.
struct YouTubePlayer: UIViewRepresentable {

    let videoID: String
    var onFailure: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the embed hands off to the system fullscreen player the
        // instant it starts, which drops it out of the sheet.
        configuration.allowsInlineMediaPlayback = true
        // A stream someone tapped "watch" on is an explicit request.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "player")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure

        // `updateUIView` runs on every parent state change, and reloading on
        // each one restarts the stream whenever the surrounding view redraws.
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        webView.loadHTMLString(YouTubePlayer.page(for: videoID),
                               baseURL: URL(string: "https://www.youtube.com"))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // The controller retains the handler, and the handler retains the
        // coordinator — without this the whole chain leaks per playback.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "player")
    }

    /// The IFrame API, in a page whose origin is youtube.com.
    ///
    /// The API script has to be framed by a page it considers same-origin,
    /// which is what `baseURL` provides. A bare navigation to `/embed/<id>`
    /// gives no callbacks at all, so a failure would be indistinguishable from
    /// a slow load.
    static func page(for videoID: String) -> String {
        let safeID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, \
        maximum-scale=1, user-scalable=no">
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
            playerVars: { playsinline: 1, autoplay: 1, rel: 0, modestbranding: 1, fs: 1 },
            events: {
              onReady: function (event) { event.target.playVideo(); report('ready'); },
              onError: function (event) { report('error:' + event.data); }
            }
          });
        }
        // If the API script itself is blocked the callback never fires, and a
        // silent black rectangle is exactly what this is meant to avoid.
        setTimeout(function () { if (!window.YT || !window.YT.Player) report('error:timeout'); }, 6000);
        </script>
        </body>
        </html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler {

        var loadedVideoID: String?
        var onFailure: () -> Void = {}

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String, body.hasPrefix("error:") else { return }
            // 101 and 150 are both "the owner disallowed embedding"; 100 is a
            // removed video; 5 is an HTML5 player failure. All of them mean the
            // embed will not play, and Safari is the answer to each.
            Task { @MainActor in self.onFailure() }
        }
    }
}

/// The sheet a live stream plays in.
struct LivePlayerSheet: View {

    let channel: LiveChannel
    let state: LiveState

    @Environment(\.dismiss) private var dismiss
    @State private var embedFailed = false
    @State private var webLink: WebLink?

    private var watchURL: URL? {
        state.videoID.flatMap(YouTubeLive.watchURL(videoID:))
    }

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
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
    }

    @ViewBuilder
    private var player: some View {
        if let videoID = state.videoID, !embedFailed {
            YouTubePlayer(videoID: videoID) { embedFailed = true }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "play.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))

                Text(embedFailed
                     ? "This channel does not allow embedded playback."
                     : "Nothing playing.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)

                if let watchURL {
                    Button {
                        webLink = WebLink(url: watchURL)
                    } label: {
                        Label("Watch in Safari", systemImage: "safari")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
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
                LiveDot()
                Text(channel.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let watchURL {
                Button {
                    webLink = WebLink(url: watchURL)
                } label: {
                    Label("Open in YouTube", systemImage: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                }
                .tint(TopicTheme.accent(.war))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
