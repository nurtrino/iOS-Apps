import Foundation

/// What has been read, and what has been kept.
///
/// Read state is bounded on purpose. An unbounded set grows forever — a few
/// hundred ids a day across eight sources — and the only thing it buys is
/// remembering that you read something in 2027 that no feed will ever mention
/// again. Old ids are dropped oldest-first once the cap is hit.
@MainActor
final class ReadStore: ObservableObject {

    /// Roughly a month of heavy reading, and about 300 KB on disk.
    private static let readCap = 8000

    @Published private(set) var readIDs: Set<String> = []
    @Published private(set) var saved: [Article] = []

    /// Insertion order, so the cap can evict the oldest rather than an
    /// arbitrary member of the set.
    private var readOrder: [String] = []

    private let readFile = "read"
    private let savedFile = "saved"
    private let readWriter = DebouncedWriter()

    init(load: Bool = true) {
        guard load else { return }
        if let stored = DiskStore.load([String].self, from: readFile) {
            readOrder = stored
            readIDs = Set(stored)
        }
        saved = DiskStore.load([Article].self, from: savedFile) ?? []
    }

    // MARK: - Read state

    func isRead(_ article: Article) -> Bool {
        readIDs.contains(article.id)
    }

    func markRead(_ article: Article) {
        guard !readIDs.contains(article.id) else { return }
        readIDs.insert(article.id)
        readOrder.append(article.id)
        trimIfNeeded()
        scheduleReadWrite()
    }

    func markUnread(_ article: Article) {
        guard readIDs.contains(article.id) else { return }
        readIDs.remove(article.id)
        readOrder.removeAll { $0 == article.id }
        scheduleReadWrite()
    }

    func markAllRead(_ articles: [Article]) {
        var changed = false
        for article in articles where !readIDs.contains(article.id) {
            readIDs.insert(article.id)
            readOrder.append(article.id)
            changed = true
        }
        guard changed else { return }
        trimIfNeeded()
        scheduleReadWrite()
    }

    func clearReadState() {
        readIDs = []
        readOrder = []
        scheduleReadWrite()
    }

    func unreadCount(in articles: [Article]) -> Int {
        articles.reduce(into: 0) { total, article in
            if !readIDs.contains(article.id) { total += 1 }
        }
    }

    private func trimIfNeeded() {
        guard readOrder.count > ReadStore.readCap else { return }
        let excess = readOrder.count - ReadStore.readCap
        for id in readOrder.prefix(excess) { readIDs.remove(id) }
        readOrder.removeFirst(excess)
    }

    private func scheduleReadWrite() {
        let snapshot = readOrder
        readWriter.schedule { DiskStore.save(snapshot, to: "read") }
    }

    // MARK: - Saved

    func isSaved(_ article: Article) -> Bool {
        saved.contains { $0.id == article.id }
    }

    func toggleSaved(_ article: Article) {
        if let index = saved.firstIndex(where: { $0.id == article.id }) {
            saved.remove(at: index)
        } else {
            // Newest first, so the list reads like a reading queue rather than
            // an archive you scroll to the bottom of.
            saved.insert(article, at: 0)
        }
        DiskStore.save(saved, to: savedFile)
    }

    func removeSaved(at offsets: IndexSet) {
        saved.remove(atOffsets: offsets)
        DiskStore.save(saved, to: savedFile)
    }

    func clearSaved() {
        saved = []
        DiskStore.save(saved, to: savedFile)
    }

    /// Forces any debounced write out — called when the app backgrounds, which
    /// is exactly when a pending write would otherwise be lost.
    func flush() {
        readWriter.flush()
    }
}
