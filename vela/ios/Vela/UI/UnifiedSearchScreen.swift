import SwiftUI

/// One search tab across both sources.
///
/// A picker rather than two search tabs: "search" is one intent, and which
/// backend answers it is a filter on that intent, not a different feature. The
/// two halves keep separate state so switching back does not throw away results
/// that cost quota to fetch.
struct UnifiedSearchScreen: View {

    enum Backend: String, CaseIterable, Identifiable {
        case youTube = "YouTube"
        case peerTube = "PeerTube"

        var id: String { rawValue }
    }

    @State private var backend: Backend = .youTube

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $backend) {
                    ForEach(Backend.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // Both stay in the hierarchy: rebuilding the inactive one on
                // every switch would discard search results that cost 100 quota
                // units to fetch.
                ZStack {
                    YouTubeSearchScreen()
                        .opacity(backend == .youTube ? 1 : 0)
                        .allowsHitTesting(backend == .youTube)

                    PeerTubeSearchBody()
                        .opacity(backend == .peerTube ? 1 : 0)
                        .allowsHitTesting(backend == .peerTube)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { uuid in
                VideoDetailScreen(uuid: uuid)
            }
            .youTubeDestinations()
        }
    }
}

/// The PeerTube half of the search tab.
///
/// Separated from `SearchScreen` because that one owns its own
/// `NavigationStack`, and nesting stacks breaks every push inside the inner
/// one.
struct PeerTubeSearchBody: View {

    @EnvironmentObject private var auth: AuthStore
    @State private var query = ""
    @State private var submitted = ""
    @State private var activeStore: VideoFeedStore?

    var body: some View {
        Group {
            if submitted.isEmpty {
                EmptyState(
                    title: "Search PeerTube",
                    message: "Find videos across this instance and the ones it federates with.",
                    systemImage: "magnifyingglass"
                )
            } else if let activeStore {
                VideoFeedList(
                    store: activeStore,
                    instance: auth.instance,
                    emptyTitle: "No results",
                    emptyMessage: "Nothing matched “\(submitted)”."
                )
            }
        }
        .searchable(text: $query, prompt: "Search PeerTube")
        .onSubmit(of: .search) { runSearch() }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != submitted else { return }
        submitted = trimmed
        let store = VideoFeedStore(source: .search(trimmed))
        store.sort = .recent
        activeStore = store
        Task { await store.loadIfNeeded() }
    }
}
