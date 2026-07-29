import SwiftUI

/// The shell: tabs, with the mini-player docked above the tab bar.
///
/// The player lives here rather than inside any one tab, because playback has
/// to survive switching tabs and pushing screens. That is also what makes the
/// mini-player possible at all — the video keeps playing while you browse for
/// the next one.
struct RootView: View {

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var auth: AuthStore

    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                YouTubeScreen()
                    .tabItem { Label("YouTube", systemImage: "play.rectangle") }
                    .tag(0)

                DiscoverScreen()
                    .tabItem { Label("PeerTube", systemImage: "sparkles") }
                    .tag(1)

                UnifiedSearchScreen()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(2)

                LibraryScreen()
                    .tabItem { Label("Library", systemImage: "arrow.down.circle") }
                    .tag(3)

                SettingsScreen()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(4)
            }
            .tint(Palette.accent)

            if player.nowPlaying != nil && !player.isExpanded {
                MiniPlayer()
                    // Clears the tab bar, which SwiftUI does not account for in
                    // an overlay.
                    .padding(.bottom, 49)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.nowPlaying)
        .fullScreenCover(isPresented: $player.isExpanded) {
            FullPlayerScreen()
        }
    }
}

/// The docked player: tap to expand, swipe down to dismiss.
struct MiniPlayer: View {

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        if let nowPlaying = player.nowPlaying {
            HStack(spacing: 12) {
                RemoteImage(url: artworkURL(for: nowPlaying))
                    .frame(width: 62, height: 35)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.video.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if nowPlaying.isOffline {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.accent)
                        }
                        Text(nowPlaying.video.channel?.displayName ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 38)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                // A hairline progress bar, which is all the position cue a
                // docked player needs.
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: geometry.size.width * progressFraction, height: 2)
                }
                .frame(height: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 8)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { player.isExpanded = true }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height < -30 {
                            player.isExpanded = true
                        } else if value.translation.height > 40 {
                            player.stop()
                        }
                    }
            )
        }
    }

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    private func artworkURL(for nowPlaying: NowPlaying) -> URL? {
        if nowPlaying.isOffline,
           let entry = DownloadManager.shared.entry(for: nowPlaying.video.uuid) {
            return entry.thumbnailURL
        }
        return auth.instance.resolve(nowPlaying.video.thumbnailPath)
    }
}
