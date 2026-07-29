import AVFoundation
import AVKit
import SwiftUI
import WebKit

/// Plays a post's video, picking the backend that can actually decode it.
///
/// Both backends loop, because 4chan video is overwhelmingly short clips that
/// are meant to loop — a player that stops on a black frame after two seconds
/// reads as broken.
struct VideoPlayerView: View {

    let board: String
    let attachment: Attachment
    var onUnsupported: (String) -> Void = { _ in }

    var body: some View {
        Group {
            switch VideoSupport.backend(for: attachment) {
            case .native:
                if let url = MediaURL.file(board: board, attachment: attachment) {
                    NativeVideoPlayer(url: url)
                } else {
                    UnsupportedVideo(message: "Couldn't build a URL for this file.", action: nil)
                }

            case .web:
                if let url = MediaURL.file(board: board, attachment: attachment) {
                    WebVideoPlayer(url: url)
                } else {
                    UnsupportedVideo(message: "Couldn't build a URL for this file.", action: nil)
                }

            case .unsupported(let reason):
                UnsupportedVideo(message: reason) {
                    onUnsupported(reason)
                }
            }
        }
        .onAppear { VideoSupport.activatePlaybackAudio() }
        .onDisappear { VideoSupport.deactivatePlaybackAudio() }
    }
}

/// AVPlayer-backed playback for containers AVFoundation understands.
private struct NativeVideoPlayer: View {

    let url: URL
    @State private var player: AVPlayer?
    /// Held so the loop observer can be torn down. Without this the observer
    /// keeps a strong reference to the player for the life of the app, and
    /// every clip opened leaks one.
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) {
                let player = AVPlayer(url: url)
                player.isMuted = false
                // Seek back to zero at the end rather than using
                // AVPlayerLooper, which needs a queue player and a good deal
                // more bookkeeping for a two-second clip.
                loopObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: player.currentItem,
                    queue: .main
                ) { [weak player] _ in
                    player?.seek(to: .zero)
                    player?.play()
                }
                self.player = player
                player.play()
            }
            .onDisappear {
                if let loopObserver {
                    NotificationCenter.default.removeObserver(loopObserver)
                }
                loopObserver = nil
                player?.pause()
                player = nil
            }
    }
}

/// WebKit-backed playback, which is the only route to WebM on iOS.
///
/// The page is a hand-written shell rather than loading the file URL directly,
/// so the video can be told to loop and to fill the viewer. `baseURL` is set to
/// the media URL so the `<video>` source counts as same-origin.
private struct WebVideoPlayer: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Empty set means no user gesture is required, so the clip starts on
        // its own the way it does on the site.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.loadHTMLString(Self.page(for: url), baseURL: url)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop the decoder and the network fetch; a WKWebView left alive keeps
        // pulling the file.
        webView.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: URL?
    }

    private static func page(for url: URL) -> String {
        // The URL comes from our own builder, but it still gets escaped: it is
        // being interpolated into markup, and "build the string carefully" is
        // not a policy that survives contact with a filename field.
        let source = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
          video { width: 100%; height: 100%; object-fit: contain; background: #000; }
        </style>
        </head>
        <body>
        <video src="\(source)" controls autoplay loop playsinline preload="auto"></video>
        </body>
        </html>
        """
    }
}

/// Shown when nothing on this device can decode the file.
private struct UnsupportedVideo: View {

    let message: String
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if let action {
                Button("Open in Browser", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
