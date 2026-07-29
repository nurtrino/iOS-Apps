import Foundation

/// Where a feed's videos come from. One store type serves every list in the
/// app, because pagination, deduplication and error handling are identical
/// across them and only the request differs.
enum FeedSource: Equatable {
    case discover
    case search(String)
    case subscriptions
    case channel(handle: String)
}

/// A paginated list of videos.
@MainActor
final class VideoFeedStore: ObservableObject {

    let source: FeedSource

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var videos: [Video] = []
    @Published private(set) var total = 0
    @Published var sort: VideoSort {
        didSet {
            guard oldValue != sort else { return }
            Task { await reload() }
        }
    }

    private static let pageSize = 24
    /// Guards against duplicates, which federation makes routine: the same
    /// video can arrive twice when an instance mirrors another, and duplicate
    /// ids crash a `ForEach`.
    private var seen: Set<String> = []

    private var hasMore: Bool { videos.count < total }

    nonisolated init(source: FeedSource, sort: VideoSort = .trending) {
        self.source = source
        self.sort = sort
    }

    func loadIfNeeded() async {
        guard videos.isEmpty, !phase.isBusy else { return }
        await load(reset: true)
    }

    func reload() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard hasMore, !phase.isBusy else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        if phase.isBusy { return }
        phase = reset ? (videos.isEmpty ? .loading : .refreshing) : .loadingMore

        let start = reset ? 0 : videos.count
        let includeNSFW = SettingsStore.shared.includeNSFW

        do {
            let page = try await fetch(start: start, includeNSFW: includeNSFW)
            if reset {
                seen = []
                videos = []
            }
            total = page.total
            for video in page.items where seen.insert(video.uuid).inserted {
                videos.append(video)
            }
            phase = .loaded
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                phase = videos.isEmpty ? .idle : .loaded
            } else {
                phase = .failed(apiError.message)
            }
        }
    }

    private func fetch(start: Int, includeNSFW: Bool) async throws -> Page<Video> {
        switch source {
        case .discover:
            return try await PeerTubeAPI.shared.videos(
                sort: sort, start: start, count: Self.pageSize, includeNSFW: includeNSFW
            )
        case .search(let query):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return Page.empty }
            return try await PeerTubeAPI.shared.search(
                trimmed, sort: sort, start: start, count: Self.pageSize, includeNSFW: includeNSFW
            )
        case .subscriptions:
            return try await PeerTubeAPI.shared.subscriptionVideos(
                start: start, count: Self.pageSize
            )
        case .channel(let handle):
            return try await PeerTubeAPI.shared.channelVideos(
                handle: handle, start: start, count: Self.pageSize
            )
        }
    }

    /// Clear everything — used when the instance changes underneath, where the
    /// existing videos belong to a server the app is no longer talking to.
    func reset() {
        videos = []
        seen = []
        total = 0
        phase = .idle
    }
}

/// One video's full detail, loaded on demand.
@MainActor
final class VideoDetailStore: ObservableObject {

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var details: VideoDetails?

    private var loadedUUID: String?

    nonisolated init() {}

    func load(uuid: String, force: Bool = false) async {
        if !force, loadedUUID == uuid, details != nil { return }
        if phase.isBusy { return }

        phase = details == nil ? .loading : .refreshing
        do {
            details = try await PeerTubeAPI.shared.video(id: uuid)
            loadedUUID = uuid
            phase = .loaded
        } catch {
            let apiError = APIError.from(error)
            phase = apiError == .cancelled ? .idle : .failed(apiError.message)
        }
    }
}
