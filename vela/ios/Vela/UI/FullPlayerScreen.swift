import AVKit
import SwiftUI

/// The expanded player: video, scrubber, transport, and the actions that only
/// make sense while something is playing.
struct FullPlayerScreen: View {

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var scrubPosition: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer(minLength: 0)

                PlayerLayerView(player: player.player, engine: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if player.isBuffering && player.isPlaying {
                            ProgressView().tint(.white).scaleEffect(1.3)
                        }
                    }

                if let failure = player.failureMessage {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                Spacer(minLength: 0)

                controls
            }
        }
        // Swipe down anywhere returns to the mini-player rather than stopping
        // playback, which is what a docked player is for.
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.height > 80 { player.isExpanded = false }
                }
        )
    }

    private var header: some View {
        HStack {
            Button {
                player.isExpanded = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            if player.nowPlaying?.isOffline == true {
                Label("Offline", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            Spacer()
            // Balances the chevron so the badge stays centred.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 4)
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if let nowPlaying = player.nowPlaying {
                VStack(spacing: 4) {
                    Text(nowPlaying.video.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(nowPlaying.video.channel?.displayName
                         ?? nowPlaying.video.account?.displayName ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 24)
            }

            scrubber

            HStack(spacing: 34) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 26))
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 62))
                }
                Button { player.skip(by: 15) } label: {
                    Image(systemName: "goforward.15").font(.system(size: 26))
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.bottom, 40)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...(max(player.duration, 1)),
                onEditingChanged: { editing in
                    // Seek on release, not continuously — scrubbing a streamed
                    // video with a seek per frame makes it stutter and hammers
                    // the server with range requests.
                    if !editing, let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                    }
                }
            )
            .tint(Palette.accent)

            HStack {
                Text(Format.time(scrubPosition ?? player.currentTime))
                Spacer()
                Text(Format.time(player.duration))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
    }
}
