import SwiftUI

/// A YouTube row.
///
/// Deliberately the same shape as `VideoCard` so a list does not visibly change
/// character when you move between sources — only the badge differs, and only
/// because what you can *do* with the two differs.
struct YouTubeVideoCard: View {

    let video: YouTubeVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(
                url: video.thumbnailURL,
                duration: video.durationLabel,
                isLive: video.isLive
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(video.channelTitle ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let views = video.viewCount {
                        Text(Format.count(views) + " views")
                    }
                    if let published = video.publishedAt {
                        if video.viewCount != nil { Text("·") }
                        Text(RelativeTime.string(from: published))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The shared list for every YouTube feed.
struct YouTubeFeedList: View {

    @ObservedObject var store: YouTubeFeedStore
    var emptyTitle: String = "Nothing here"
    var emptyMessage: String?

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                LoadingState()

            case .failed(let message) where store.videos.isEmpty:
                ErrorState(message: message) {
                    Task { await store.reload() }
                }

            default:
                if store.videos.isEmpty {
                    EmptyState(title: emptyTitle, message: emptyMessage, systemImage: "play.rectangle")
                } else {
                    list
                }
            }
        }
        .refreshable { await store.reload() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                ForEach(store.videos) { video in
                    NavigationLink(value: YouTubeRoute.watch(video)) {
                        YouTubeVideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if video.id == store.videos.suffix(4).first?.id {
                            Task { await store.loadMore() }
                        }
                    }
                }

                if store.phase == .loadingMore {
                    ProgressView().padding(.vertical, 12)
                }

                if let message = store.phase.errorMessage, !store.videos.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
    }
}

/// Where a YouTube navigation link goes.
///
/// The whole video travels rather than just its id: the watch screen can render
/// its title and channel immediately from what the list already had, instead of
/// showing a spinner while it re-fetches something it was just handed.
enum YouTubeRoute: Hashable {
    case watch(YouTubeVideo)
    case channel(String)
}

extension YouTubeVideo: Hashable {
    static func == (lhs: YouTubeVideo, rhs: YouTubeVideo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Trending.
struct YouTubeScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var keys: APIKeyStatus
    @StateObject private var store = YouTubeFeedStore(source: .trending)

    var body: some View {
        NavigationStack {
            Group {
                if keys.hasKey {
                    YouTubeFeedList(
                        store: store,
                        emptyTitle: "No trending videos",
                        emptyMessage: "YouTube returned nothing for this region."
                    )
                } else {
                    MissingKeyPrompt()
                }
            }
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if keys.hasKey {
                        QuotaBadge(spent: store.spentUnits)
                    }
                }
            }
            .youTubeDestinations()
        }
        .task(id: taskKey) {
            guard keys.hasKey else { return }
            store.reset()
            await store.loadIfNeeded()
        }
    }

    /// Re-runs when either the key or the region changes, both of which
    /// invalidate the loaded chart.
    private var taskKey: String {
        "\(keys.hasKey)-\(settings.trendingRegion)"
    }
}

/// YouTube search.
struct YouTubeSearchScreen: View {

    @EnvironmentObject private var keys: APIKeyStatus
    @State private var query = ""
    @State private var submitted = ""
    @State private var activeStore: YouTubeFeedStore?
    @State private var order: YouTubeSearchOrder = .relevance

    var body: some View {
        Group {
            if !keys.hasKey {
                MissingKeyPrompt()
            } else if submitted.isEmpty {
                EmptyState(
                    title: "Search YouTube",
                    message: "Each search costs 100 of the key's 10,000 daily quota units, so results are kept until you search again.",
                    systemImage: "magnifyingglass"
                )
            } else if let activeStore {
                YouTubeFeedList(
                    store: activeStore,
                    emptyTitle: "No results",
                    emptyMessage: "Nothing matched “\(submitted)”."
                )
            }
        }
        .searchable(text: $query, prompt: "Search YouTube")
        // Submit rather than search-as-you-type: at 100 units a call, a search
        // per keystroke would spend the day's entire budget on one word.
        .onSubmit(of: .search) { runSearch() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !submitted.isEmpty {
                    Menu {
                        Picker("Sort", selection: Binding(
                            get: { order },
                            set: { newOrder in
                                guard newOrder != order else { return }
                                order = newOrder
                                activeStore?.order = newOrder
                                Task { await activeStore?.reload() }
                            }
                        )) {
                            ForEach(YouTubeSearchOrder.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != submitted else { return }
        submitted = trimmed
        let store = YouTubeFeedStore(source: .search(trimmed))
        store.order = order
        activeStore = store
        Task { await store.loadIfNeeded() }
    }
}

/// A channel's uploads.
struct YouTubeChannelScreen: View {

    let channelID: String

    @StateObject private var channelStore = YouTubeChannelStore()
    @State private var feedStore: YouTubeFeedStore?

    var body: some View {
        Group {
            switch channelStore.phase {
            case .loading, .idle:
                LoadingState()
            case .failed(let message):
                ErrorState(message: message) {
                    Task { await channelStore.load(id: channelID) }
                }
            default:
                if let feedStore {
                    YouTubeFeedList(store: feedStore, emptyTitle: "No uploads")
                } else {
                    EmptyState(
                        title: "No uploads",
                        message: "This channel has no public uploads playlist.",
                        systemImage: "play.rectangle"
                    )
                }
            }
        }
        .navigationTitle(channelStore.channel?.title ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: channelID) {
            await channelStore.load(id: channelID)
            // Uploads are listed through the channel's own playlist: 1 quota
            // unit, against 100 for the equivalent channel search.
            guard let playlistID = channelStore.channel?.uploadsPlaylistID else { return }
            let store = YouTubeFeedStore(source: .channelUploads(playlistID: playlistID))
            feedStore = store
            await store.loadIfNeeded()
        }
    }
}

/// Watching one video.
struct YouTubeWatchScreen: View {

    let video: YouTubeVideo

    @StateObject private var controller = YouTubeEmbedController()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Color.black
                    if controller.embedRefused {
                        embedRefusedNotice
                    } else {
                        YouTubeEmbedView(videoID: video.id, controller: controller)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title)
                        .font(.system(size: 18, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if let views = video.viewCount {
                            Text(Format.count(views) + " views")
                        }
                        if let published = video.publishedAt {
                            if video.viewCount != nil { Text("·") }
                            Text(RelativeTime.string(from: published))
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                    if let channelTitle = video.channelTitle, let channelID = video.channelID {
                        NavigationLink(value: YouTubeRoute.channel(channelID)) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.secondary)
                                Text(channelTitle)
                                    .font(.system(size: 15, weight: .medium))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.top, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                capabilityNote

                if let url = video.watchURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { controller.stop() }
    }

    /// Says plainly why this screen has no download or background-audio button
    /// when the PeerTube side of the app does.
    private var capabilityNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("YouTube videos play in YouTube's own player, which serves their ads and stops when the app goes to the background. Downloads, background audio and Picture in Picture work on the PeerTube tab, where the server hands out the actual file.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var embedRefusedNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("This video can't be embedded")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("The uploader or rights holder disabled playback outside YouTube.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Shared pieces

/// Applies the YouTube navigation destinations to a stack.
///
/// An extension rather than repetition: the watch screen links to channels and
/// channel screens link back to videos, so every stack hosting either needs
/// both registered.
extension View {
    func youTubeDestinations() -> some View {
        navigationDestination(for: YouTubeRoute.self) { route in
            switch route {
            case .watch(let video):
                YouTubeWatchScreen(video: video)
            case .channel(let id):
                YouTubeChannelScreen(channelID: id)
            }
        }
    }
}

/// Shows what the day's quota has gone on.
///
/// Visible because the failure it predicts is otherwise baffling: the app works
/// all morning and then every search returns an error until midnight Pacific.
struct QuotaBadge: View {

    let spent: Int

    private var fraction: Double { min(1, Double(spent) / 10_000) }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(fraction > 0.9 ? Color.orange : Palette.accent)
                .frame(width: 6, height: 6)
            Text("\(spent)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(spent) of 10,000 daily quota units used")
    }
}

/// Shown wherever YouTube content would be, before a key exists.
struct MissingKeyPrompt: View {

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Add a YouTube API key")
                .font(.headline)
            Text("Browsing YouTube needs a Data API key from a Google Cloud project. It's free, takes a couple of minutes, and the key stays in this device's Keychain.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Add Key") { showingSettings = true }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingSettings) { APIKeySheet() }
    }
}
