import Foundation

/// One open thread.
///
/// The whole thread arrives in one request, so loading is a single call with no
/// partial state to model. What this type actually manages is everything
/// *around* that: the derived outline, collapse state, filtering, auto-refresh
/// within the site's stated limits, and the "N new posts" marker.
@MainActor
final class ThreadStore: ObservableObject {

    let board: String
    let threadNo: Int

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var index: ThreadIndex?
    @Published private(set) var lastUpdated: Date?
    /// Set when the thread 404s — the ordinary end of a thread's life on a fast
    /// board, not an error to retry.
    @Published private(set) var isDead = false

    /// Posts that arrived since the last load, so the view can mark them.
    @Published private(set) var newPostNumbers: Set<Int> = []

    @Published var viewMode: ThreadViewMode = .chronological {
        didSet { rebuildOutline() }
    }
    @Published private(set) var collapsed: Set<Int> = [] {
        didSet { rebuildDerived() }
    }

    /// The full outline for the current view mode.
    @Published private(set) var outline: [ThreadNode] = []
    /// The outline after filters and collapse — what the list actually renders.
    @Published private(set) var visibleNodes: [ThreadNode] = []
    /// Descendant count per post, for the badge on a collapsed row.
    @Published private(set) var descendantCounts: [Int: Int] = [:]

    private let api: ChanAPI
    private var refreshTask: Task<Void, Never>?

    /// `nonisolated` so `ThreadScreen.init` can build one for `@StateObject`.
    /// See `CatalogStore.init` for why `FilterStore` is not held here.
    nonisolated init(board: String, threadNo: Int) {
        self.board = board
        self.threadNo = threadNo
        self.api = ChanAPI.shared
    }

    private var filters: FilterStore { FilterStore.shared }

    var op: Post? { index?.op }

    var title: String {
        if let subject = op?.subject, !subject.isEmpty { return subject }
        if let comment = op?.comment {
            let text = CommentParserCache.shared.blocks(for: comment)
                .compactMap { block -> String? in
                    if case .paragraph(let paragraph) = block { return paragraph.text }
                    return nil
                }
                .joined(separator: " ")
            if !text.isEmpty { return String(text.prefix(80)) }
        }
        return "Thread \(threadNo)"
    }

    var replyCount: Int { max(0, (index?.posts.count ?? 0) - 1) }

    var posterCount: Int? {
        if let unique = op?.uniqueIPs { return unique }
        guard let index, !index.distinctPosterIDs.isEmpty else { return nil }
        return index.distinctPosterIDs.count
    }

    /// How many posts the filter list removed.
    ///
    /// Measured when the filter pass runs, not derived by subtracting the
    /// visible count: collapse also removes nodes, and nested collapsed
    /// subtrees overlap, so any arithmetic over `descendantCounts`
    /// double-counts and reports a number that is simply wrong.
    @Published private(set) var hiddenByFiltersCount = 0

    func post(_ no: Int) -> Post? { index?.post(no) }

    func replies(to no: Int) -> [Int] { index?.replies(to: no) ?? [] }

    /// Ancestors of a post, but only when the view is actually nesting.
    ///
    /// The threaded view uses this to drop the redundant `>>parent` line from
    /// the top of a reply. In chronological mode that line is the *only* thing
    /// saying who is being answered, so it has to stay — hence the empty set.
    func ancestors(of no: Int) -> Set<Int> {
        guard viewMode == .threaded, let index else { return [] }
        return Set(index.ancestors(of: no))
    }

    // MARK: - Loading

    func load(force: Bool = false) async {
        if phase.isBusy { return }
        let hadContent = index != nil
        phase = hadContent ? .refreshing : .loading

        do {
            let response = try await api.thread(board: board, no: threadNo, forceRefresh: force)
            let previous = Set(index?.posts.map(\.no) ?? [])
            let newIndex = ThreadIndex(board: board, posts: response.posts)

            if hadContent {
                newPostNumbers = Set(newIndex.posts.map(\.no)).subtracting(previous)
            }
            index = newIndex
            isDead = false
            lastUpdated = Date()
            rebuildOutline()
            phase = .loaded

            LibraryStore.shared.updateKnownReplyCount(
                board: board, no: threadNo, replyCount: max(0, newIndex.posts.count - 1)
            )
        } catch {
            let chanError = ChanError.from(error)
            switch chanError {
            case .cancelled:
                phase = index == nil ? .idle : .loaded
            case .notFound:
                isDead = true
                stopAutoRefresh()
                LibraryStore.shared.markDead(board: board, no: threadNo)
                // A pruned thread we already have is still worth reading; only
                // report the failure when there is nothing on screen.
                phase = index == nil ? .failed(chanError.message) : .loaded
            default:
                phase = index == nil ? .failed(chanError.message) : .loaded
            }
        }
    }

    func loadIfNeeded() async {
        guard index == nil, !phase.isBusy else { return }
        await load()
    }

    // MARK: - Auto refresh

    /// The API documentation asks that thread updating be no more frequent than
    /// every 10 seconds; `RefreshInterval` offers nothing shorter, and this
    /// clamps regardless in case that ever changes.
    func startAutoRefresh(interval: RefreshInterval) {
        stopAutoRefresh()
        guard interval != .off, !isDead else { return }
        let seconds = max(10, interval.rawValue)

        // This closure inherits main-actor isolation from the enclosing type,
        // so only the genuinely async calls are awaited — `isDead` is a plain
        // isolated read and awaiting it would just be flagged as redundant.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.load(force: true)
                if self.isDead { return }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Collapse

    func toggleCollapse(_ postNo: Int) {
        if collapsed.contains(postNo) {
            collapsed.remove(postNo)
        } else {
            collapsed.insert(postNo)
        }
    }

    func isCollapsed(_ postNo: Int) -> Bool { collapsed.contains(postNo) }

    func expandAll() { collapsed = [] }

    func collapseAll() {
        guard viewMode == .threaded else { return }
        collapsed = Set(outline.filter { $0.depth == 1 }.map(\.postNo))
    }

    /// Clear the new-post markers once the reader has had a chance to see them.
    func acknowledgeNewPosts() {
        guard !newPostNumbers.isEmpty else { return }
        newPostNumbers = []
    }

    // MARK: - Derived state

    func applyAutoCollapse(depth: Int) {
        guard depth > 0, viewMode == .threaded else { return }
        collapsed = Set(outline.filter { $0.depth == depth }.map(\.postNo))
    }

    private func rebuildOutline() {
        guard let index else {
            outline = []
            visibleNodes = []
            descendantCounts = [:]
            return
        }
        outline = viewMode == .threaded ? index.threadedOutline() : index.flatOutline()
        rebuildDerived()
    }

    /// Recomputed on change rather than per frame: a long thread re-deriving
    /// this during scrolling is exactly the stutter the flat-outline design
    /// exists to avoid.
    private func rebuildDerived() {
        guard let index else {
            visibleNodes = []
            descendantCounts = [:]
            hiddenByFiltersCount = 0
            return
        }

        let counts = Outline.descendantCounts(outline)
        var byPost: [Int: Int] = [:]
        byPost.reserveCapacity(outline.count)
        for (offset, node) in outline.enumerated() {
            byPost[node.postNo] = counts[offset]
        }
        descendantCounts = byPost

        var nodes = outline
        if !filters.isEmpty {
            let activeFilters = filters
            nodes = Outline.filtered(nodes) { postNo in
                guard let post = index.post(postNo) else { return true }
                // The OP is never hidden: hiding it would take the whole thread
                // with it, which is the catalog's job, not the thread view's.
                if post.isOP { return true }
                return !activeFilters.hides(post)
            }
        }
        hiddenByFiltersCount = outline.count - nodes.count
        visibleNodes = Outline.visible(nodes, collapsed: collapsed)
    }

    /// Rebuild after the filter list changes underneath an open thread.
    func filtersChanged() {
        rebuildDerived()
    }
}
