import SwiftUI
import WebKit

/// Plays a YouTube stream inside the app.
///
/// A `WKWebView` around the official embed rather than `AVPlayer` around an
/// extracted stream URL. That is not a shortcut — it is the only legitimate
/// option. YouTube's media URLs are signed, short-lived and explicitly not for
/// third-party players, and an app that scrapes them breaks the moment the
/// signature scheme changes and violates the terms in the meantime. The embed
/// is a supported, documented surface, and it carries the ads and counts the
/// view, which is what the channel is owed for the stream you are watching.
struct YouTubePlayer: UIViewRepresentable {

    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the embed hands off to the system fullscreen player the
        // instant it starts, which drops it out of the sheet.
        configuration.allowsInlineMediaPlayback = true
        // A live stream someone tapped "watch" on is an explicit request, so
        // it may start on its own.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url = YouTubeLive.embedURL(videoID: videoID) else { return }
        // Only reload when the video actually changed. `updateUIView` runs on
        // every parent state change, and reloading on each one restarts the
        // stream every time the surrounding view redraws.
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedVideoID: String?
    }
}

/// The sheet the player lives in.
struct LivePlayerSheet: View {

    let channel: LiveChannel
    let state: LiveState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let videoID = state.videoID {
                    YouTubePlayer(videoID: videoID)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                } else {
                    StateView(systemImage: "play.slash",
                              title: "Nothing playing",
                              message: "This channel is not live right now.")
                }

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
                    if let url = state.videoID.flatMap(YouTubeLive.watchURL(videoID:)) {
                        Link(destination: url) {
                            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .tint(TopicTheme.accent(.war))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                Spacer()
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
}

/// The pulsing red dot. Small, but it is the thing the eye goes to on a
/// monitoring screen, so it earns its own view.
struct LiveDot: View {

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .scaleEffect(isPulsing ? 1.0 : 0.72)
            .opacity(isPulsing ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}
