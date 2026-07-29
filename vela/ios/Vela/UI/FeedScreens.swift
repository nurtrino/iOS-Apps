import SwiftUI

/// The list every feed uses.
///
/// Discover, search, subscriptions and channels differ only in the request they
/// make, so they share one list: pagination, deduplication, the empty state and
/// the retry all behave identically no matter which tab you are on.
struct VideoFeedList: View {

    @ObservedObject var store: VideoFeedStore
    let instance: Instance
    var emptyTitle: String = "Nothing here yet"
    var emptyMessage: String?

    @EnvironmentObject private var downloads: DownloadManager

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
                    EmptyState(title: emptyTitle, message: emptyMessage, systemImage: "film")
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
                    NavigationLink(value: video.uuid) {
                        VideoCard(
                            video: video,
                            instance: instance,
                            isDownloaded: downloads.isDownloaded(video.uuid)
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Prefetch a screen early rather than at the very last
                        // row, so the list rarely shows a spinner mid-scroll.
                        if video.uuid == store.videos.suffix(4).first?.uuid {
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
            // Clears the docked mini-player so the last row is never trapped
            // underneath it.
            .padding(.bottom, 120)
        }
    }
}

struct DiscoverScreen: View {

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var store = VideoFeedStore(source: .discover)
    @State private var showingFollowing = false

    var body: some View {
        NavigationStack {
            VideoFeedList(
                store: store,
                instance: auth.instance,
                emptyTitle: "No videos",
                emptyMessage: "This instance hasn't published anything yet, or it's unreachable."
            )
            .navigationTitle(auth.instanceConfig?.name ?? auth.instance.host)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Following moved off the tab bar to make room for YouTube.
                // A sheet rather than a push, because it owns its own stack.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingFollowing = true
                    } label: {
                        Image(systemName: "person.2")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sort", selection: Binding(
                            get: { store.sort },
                            set: { newSort in
                                guard newSort != store.sort else { return }
                                store.sort = newSort
                                Task { await store.reload() }
                            }
                        )) {
                            ForEach(VideoSort.allCases) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(for: String.self) { uuid in
                VideoDetailScreen(uuid: uuid)
            }
            .sheet(isPresented: $showingFollowing) { SubscriptionsScreen() }
        }
        // Keyed on the instance: switching servers must refetch, and without an
        // id the task would never re-run.
        .task(id: auth.instance) {
            store.reset()
            store.sort = settings.defaultSort
            await store.loadIfNeeded()
        }
    }
}

// PeerTube search now lives in `UnifiedSearchScreen` alongside the YouTube
// half, as `PeerTubeSearchBody` — it had to lose its own `NavigationStack`,
// since nesting one inside the search tab's stack breaks every push.

struct SubscriptionsScreen: View {

    @EnvironmentObject private var auth: AuthStore
    @StateObject private var store = VideoFeedStore(source: .subscriptions)

    var body: some View {
        NavigationStack {
            Group {
                if auth.isSignedIn {
                    VideoFeedList(
                        store: store,
                        instance: auth.instance,
                        emptyTitle: "Nothing new",
                        emptyMessage: "Videos from channels you follow will appear here."
                    )
                } else {
                    SignedOutPrompt()
                }
            }
            .navigationTitle("Following")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { uuid in
                VideoDetailScreen(uuid: uuid)
            }
        }
        // Reloads when somebody signs in or out, which changes whether this
        // request is even possible.
        .task(id: auth.user?.username) {
            store.reset()
            store.sort = .recent
            guard auth.isSignedIn else { return }
            await store.loadIfNeeded()
        }
    }
}

/// Shown in place of the subscriptions feed when nobody is signed in.
///
/// Sign-in is optional in this app: PeerTube serves its catalogue anonymously,
/// so an account buys a following list, not access.
struct SignedOutPrompt: View {

    @State private var showingSignIn = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign in to follow channels")
                .font(.headline)
            Text("Everything else works without an account — signing in just brings your subscriptions along.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Sign In") { showingSignIn = true }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingSignIn) { SignInSheet() }
    }
}
