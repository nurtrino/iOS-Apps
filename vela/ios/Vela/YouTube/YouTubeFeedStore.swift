import Foundation

/// Where a YouTube feed's videos come from.
enum YouTubeFeedSource: Equatable {
    case trending
    case search(String)
    /// Listed through the channel's uploads playlist, which is 1 quota unit
    /// against the 100 a channel search would cost.
    case channelUploads(playlistID: String)
}

/// A paginated YouTube feed.
///
/// Mirrors `VideoFeedStore` deliberately — same phases, same dedup, same
/// prefetch — so the list view does not care which backend a feed came from.
/// The one behaviour unique to this side is the enrichment pass: search results
/// come back without durations or view counts, and a second call fills them in
/// for a single quota unit rather than leaving every row bare.
@MainActor
final class YouTubeFeedStore: ObservableObject {

    let source: YouTubeFeedSource

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var videos: [YouTubeVideo] = []
    @Published private(set) var spentUnits = 0
    @Published var order: YouTubeSearchOrder = .relevance

    private static let pageSize = 25

    private var nextPageToken: String?
    private var seen: Set<String> = []
    private var hasLoadedOnce = false

    private var hasMore: Bool { nextPageToken != nil }

    /// `nonisolated` because a SwiftUI property initialiser is not main-actor
    /// isolated. It assigns only the plain `let`.
    nonisolated init(source: YouTubeFeedSource) {
        self.source = source
    }

    func loadIfNeeded() async {
        guard !hasLoadedOnce, !phase.isBusy else { return }
        await load(reset: true)
    }

    func reload() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard hasMore, !phase.isBusy else { return }
        await load(reset: false)
    }

    func reset() {
        videos = []
        seen = []
        nextPageToken = nil
        hasLoadedOnce = false
        phase = .idle
    }

    private func load(reset: Bool) async {
        if phase.isBusy { return }
        phase = reset ? (videos.isEmpty ? .loading : .refreshing) : .loadingMore

        let token = reset ? nil : nextPageToken
        let region = SettingsStore.shared.trendingRegion

        do {
            let page = try await fetch(pageToken: token, region: region)
            let enriched = try await enrich(page.items)

            if reset {
                seen = []
                videos = []
            }
            nextPageToken = page.nextPageToken
            for video in enriched where seen.insert(video.id).inserted {
                videos.append(video)
            }
            hasLoadedOnce = true
            phase = .loaded
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                phase = videos.isEmpty ? .idle : .loaded
            } else {
                phase = .failed(apiError.message)
            }
        }

        spentUnits = await YouTubeAPI.shared.spentUnits
    }

    private func fetch(pageToken: String?,
                       region: String) async throws -> YouTubePage<YouTubeVideo> {
        switch source {
        case .trending:
            return try await YouTubeAPI.shared.trending(
                regionCode: region, pageToken: pageToken, count: Self.pageSize
            )
        case .search(let query):
            return try await YouTubeAPI.shared.search(
                query, order: order, pageToken: pageToken, count: Self.pageSize
            )
        case .channelUploads(let playlistID):
            return try await YouTubeAPI.shared.playlistItems(
                playlistID: playlistID, pageToken: pageToken, count: Self.pageSize
            )
        }
    }

    /// Fills in durations and view counts for rows that arrived without them.
    ///
    /// One batched call for the whole page, costing 1 unit. If it fails the
    /// original rows are kept: a missing duration label is a much smaller loss
    /// than an empty feed, so this never propagates its error.
    private func enrich(_ items: [YouTubeVideo]) async throws -> [YouTubeVideo] {
        let incomplete = items.filter { $0.durationSeconds == nil }
        guard !incomplete.isEmpty else { return items }

        guard let detailed = try? await YouTubeAPI.shared.videos(ids: incomplete.map(\.id)) else {
            return items
        }
        let byID = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.map { byID[$0.id] ?? $0 }
    }
}

/// One channel, loaded on demand.
@MainActor
final class YouTubeChannelStore: ObservableObject {

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var channel: YouTubeChannel?

    private var loadedID: String?

    nonisolated init() {}

    func load(id: String) async {
        if loadedID == id, channel != nil { return }
        if phase.isBusy { return }

        phase = .loading
        do {
            channel = try await YouTubeAPI.shared.channel(id: id)
            loadedID = id
            phase = .loaded
        } catch {
            let apiError = APIError.from(error)
            phase = apiError == .cancelled ? .idle : .failed(apiError.message)
        }
    }
}
