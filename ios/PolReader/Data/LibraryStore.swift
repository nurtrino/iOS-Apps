import Foundation

/// A thread the reader has explicitly kept.
///
/// Threads on /pol/ are short-lived — the board runs fast enough that most fall
/// off within hours — so "watching" one is mostly about noticing new replies
/// before it dies, and noticing when it has.
struct WatchedThread: Codable, Identifiable, Hashable {
    let board: String
    let no: Int
    /// Snapshotted at save time: once the thread is pruned there is nothing
    /// left to derive a title from.
    var title: String
    var savedAt: Date
    /// Reply count when the reader last opened it, for the "+12" badge.
    var lastSeenReplyCount: Int
    var lastKnownReplyCount: Int
    /// Set once the thread 404s, so the row can say so instead of failing
    /// silently every refresh.
    var isDead: Bool

    var id: String { "\(board)/\(no)" }

    var unreadCount: Int { max(0, lastKnownReplyCount - lastSeenReplyCount) }
}

/// Watched threads and read state, on disk, local only.
@MainActor
final class LibraryStore: ObservableObject {

    static let shared = LibraryStore()

    /// Read-thread ids are capped newest-first. A reader who never clears this
    /// would otherwise accumulate an unbounded list of a board that turns over
    /// hundreds of threads a day.
    private static let readIDLimit = 5000

    private static let watchedFile = "watched"
    private static let readFile = "read"

    @Published private(set) var watched: [WatchedThread] = []
    /// Newest first.
    @Published private(set) var readThreadIDs: [String] = []

    private var readLookup: Set<String> = []
    private let watchedWriter = DebouncedWriter()
    private let readWriter = DebouncedWriter()

    init(loadFromDisk: Bool = true) {
        guard loadFromDisk else { return }
        watched = DiskStore.load([WatchedThread].self, from: Self.watchedFile) ?? []
        readThreadIDs = DiskStore.load([String].self, from: Self.readFile) ?? []
        readLookup = Set(readThreadIDs)
    }

    // MARK: - Watching

    func isWatching(board: String, no: Int) -> Bool {
        watched.contains { $0.board == board && $0.no == no }
    }

    func watch(board: String, no: Int, title: String, replyCount: Int) {
        guard !isWatching(board: board, no: no) else { return }
        watched.insert(
            WatchedThread(board: board, no: no, title: title, savedAt: Date(),
                          lastSeenReplyCount: replyCount, lastKnownReplyCount: replyCount,
                          isDead: false),
            at: 0
        )
        persistWatched()
    }

    func unwatch(board: String, no: Int) {
        watched.removeAll { $0.board == board && $0.no == no }
        persistWatched()
    }

    func toggleWatch(board: String, no: Int, title: String, replyCount: Int) {
        if isWatching(board: board, no: no) {
            unwatch(board: board, no: no)
        } else {
            watch(board: board, no: no, title: title, replyCount: replyCount)
        }
    }

    /// Record what the reader has now seen, clearing the unread badge.
    func markSeen(board: String, no: Int, replyCount: Int) {
        guard let index = watched.firstIndex(where: { $0.board == board && $0.no == no }) else { return }
        watched[index].lastSeenReplyCount = replyCount
        watched[index].lastKnownReplyCount = max(watched[index].lastKnownReplyCount, replyCount)
        persistWatched()
    }

    func updateKnownReplyCount(board: String, no: Int, replyCount: Int) {
        guard let index = watched.firstIndex(where: { $0.board == board && $0.no == no }) else { return }
        guard watched[index].lastKnownReplyCount != replyCount || watched[index].isDead else { return }
        watched[index].lastKnownReplyCount = replyCount
        watched[index].isDead = false
        persistWatched()
    }

    func markDead(board: String, no: Int) {
        guard let index = watched.firstIndex(where: { $0.board == board && $0.no == no }) else { return }
        guard !watched[index].isDead else { return }
        watched[index].isDead = true
        persistWatched()
    }

    func clearWatched() {
        watched = []
        persistWatched()
    }

    // MARK: - Read state

    func isRead(board: String, no: Int) -> Bool {
        readLookup.contains("\(board)/\(no)")
    }

    func markRead(board: String, no: Int) {
        let key = "\(board)/\(no)"
        guard !readLookup.contains(key) else { return }
        readLookup.insert(key)
        readThreadIDs.insert(key, at: 0)
        if readThreadIDs.count > Self.readIDLimit {
            let dropped = readThreadIDs[Self.readIDLimit...]
            readLookup.subtract(dropped)
            readThreadIDs.removeLast(readThreadIDs.count - Self.readIDLimit)
        }
        persistRead()
    }

    func clearRead() {
        readThreadIDs = []
        readLookup = []
        persistRead()
    }

    // MARK: - Persistence

    private func persistWatched() {
        let snapshot = watched
        watchedWriter.schedule { DiskStore.save(snapshot, to: Self.watchedFile) }
    }

    private func persistRead() {
        let snapshot = readThreadIDs
        readWriter.schedule { DiskStore.save(snapshot, to: Self.readFile) }
    }

    /// Force pending writes out. Called when the app leaves the foreground,
    /// where a debounced write would otherwise be lost.
    func flush() {
        watchedWriter.flush()
        readWriter.flush()
    }
}
