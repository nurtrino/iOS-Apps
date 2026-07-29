import Foundation

enum CatalogSort: String, CaseIterable, Identifiable {
    /// The order the API returns, which is the board's own bump order.
    case bumpOrder
    case replyCount
    case imageCount
    case newest
    case lastModified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bumpOrder: return "Bump order"
        case .replyCount: return "Replies"
        case .imageCount: return "Images"
        case .newest: return "Newest"
        case .lastModified: return "Last reply"
        }
    }
}

/// The catalog for one board.
///
/// `catalog.json` returns **the entire board in a single response** — every
/// page, every OP, with a few preview replies each. So there is no pagination
/// behind scrolling and no id-list to hydrate in batches. `visibleCount` exists
/// only to bound how many rows SwiftUI is asked to build at once.
///
/// One of these is kept alive for the app's lifetime so switching tabs
/// preserves scroll position and content instead of refetching.
@MainActor
final class CatalogStore: ObservableObject {

    let board: String

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var allThreads: [CatalogThread] = []
    @Published private(set) var lastUpdated: Date?

    @Published var searchText: String = "" {
        didSet { resetPagination() }
    }
    @Published var sort: CatalogSort = .bumpOrder {
        didSet { resetPagination() }
    }

    private static let pageSize = 30
    @Published private(set) var visibleCount = CatalogStore.pageSize

    private let api: ChanAPI

    /// `nonisolated` so a SwiftUI `View.init` — which is not itself
    /// main-actor-isolated — can build one for `@StateObject`. Only stored
    /// properties are touched here; `ChanAPI` is an actor, so its `shared` is
    /// reachable from any context, whereas `FilterStore.shared` is main-actor
    /// bound and is therefore read inside isolated methods instead of held.
    nonisolated init(board: String = "pol") {
        self.board = board
        self.api = ChanAPI.shared
    }

    private var filters: FilterStore { FilterStore.shared }

    /// Threads after filtering, searching and sorting — but before pagination.
    var matchingThreads: [CatalogThread] {
        var result = allThreads

        if !filters.isEmpty {
            result = result.filter { !filters.hides($0) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { thread in
                if let subject = thread.op.subject,
                   subject.range(of: query, options: .caseInsensitive) != nil {
                    return true
                }
                if let comment = thread.op.comment {
                    let text = CommentParserCache.shared.blocks(for: comment)
                        .compactMap { block -> String? in
                            if case .paragraph(let paragraph) = block { return paragraph.text }
                            return nil
                        }
                        .joined(separator: "\n")
                    if text.range(of: query, options: .caseInsensitive) != nil { return true }
                }
                return false
            }
        }

        switch sort {
        case .bumpOrder:
            break
        case .replyCount:
            result.sort { $0.replyCount > $1.replyCount }
        case .imageCount:
            result.sort { $0.imageCount > $1.imageCount }
        case .newest:
            result.sort { $0.op.time > $1.op.time }
        case .lastModified:
            result.sort { ($0.lastModified ?? $0.op.time) > ($1.lastModified ?? $1.op.time) }
        }

        return result
    }

    var displayedThreads: [CatalogThread] {
        Array(matchingThreads.prefix(visibleCount))
    }

    var hasMoreToShow: Bool {
        visibleCount < matchingThreads.count
    }

    var hiddenByFiltersCount: Int {
        guard !filters.isEmpty else { return 0 }
        return allThreads.count - allThreads.filter { !filters.hides($0) }.count
    }

    func showMore() {
        guard hasMoreToShow else { return }
        visibleCount += Self.pageSize
    }

    private func resetPagination() {
        visibleCount = Self.pageSize
    }

    func load(force: Bool = false) async {
        if phase.isBusy { return }
        phase = allThreads.isEmpty ? .loading : .refreshing

        do {
            let pages = try await api.catalog(board: board, forceRefresh: force)
            let threads = pages
                .sorted { $0.page < $1.page }
                .flatMap(\.threads)
            allThreads = threads
            lastUpdated = Date()
            resetPagination()
            phase = .loaded
        } catch {
            let chanError = ChanError.from(error)
            if chanError == .cancelled {
                phase = allThreads.isEmpty ? .idle : .loaded
            } else {
                phase = .failed(chanError.message)
            }
        }
    }

    /// Load only if there is nothing to show. Used on first appearance so that
    /// returning to a tab does not refetch a catalog that is already there.
    func loadIfNeeded() async {
        guard allThreads.isEmpty, !phase.isBusy else { return }
        await load()
    }
}
