import Foundation

/// Which stories have been read, and which are saved for later.
///
/// Saved articles keep their whole payload, not just the id — a bookmark that
/// evaporates when the story scrolls out of the feed is not a bookmark.
@MainActor
final class ArticleStateStore: ObservableObject {

    private static let readKey = "readArticleIDs"
    private static let savedKey = "savedArticles"

    private let defaults = UserDefaults.standard

    @Published private(set) var readIDs: Set<String>
    @Published private(set) var saved: [Article]

    init() {
        readIDs = Set(defaults.array(forKey: Self.readKey) as? [String] ?? [])
        if let data = defaults.data(forKey: Self.savedKey),
           let decoded = try? JSONDecoder().decode([Article].self, from: data) {
            saved = decoded
        } else {
            saved = []
        }
    }

    func isRead(_ article: Article) -> Bool {
        readIDs.contains(article.id)
    }

    func markRead(_ article: Article) {
        guard readIDs.insert(article.id).inserted else { return }
        persistRead()
    }

    func isSaved(_ article: Article) -> Bool {
        saved.contains { $0.id == article.id }
    }

    func toggleSaved(_ article: Article) {
        if let index = saved.firstIndex(where: { $0.id == article.id }) {
            saved.remove(at: index)
        } else {
            saved.insert(article, at: 0)
        }
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.savedKey)
        }
    }

    private func persistRead() {
        // Capped so a year of reading does not become a megabyte of plist.
        // Which ids survive the cap barely matters — an old article marked
        // unread again has long scrolled out of every feed.
        var ids = Array(readIDs)
        if ids.count > 1500 { ids = Array(ids.suffix(1500)) }
        defaults.set(ids, forKey: Self.readKey)
    }
}

/// The ids the app has ever seen, for the background refresh to diff against.
///
/// Not `@MainActor` and not observable: the background task is the consumer,
/// and all it needs is "which of these articles are genuinely new since the
/// user last looked".
enum SeenStore {

    private static let key = "seenArticleIDs"
    private static let cap = 1200

    static var hasBaseline: Bool {
        !(UserDefaults.standard.array(forKey: key) as? [String] ?? []).isEmpty
    }

    static func unseen(from articles: [Article]) -> [Article] {
        let seen = Set(UserDefaults.standard.array(forKey: key) as? [String] ?? [])
        return articles.filter { !seen.contains($0.id) }
    }

    static func merge(_ ids: [String]) {
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let existing = Set(stored)
        stored += ids.filter { !existing.contains($0) }
        if stored.count > cap { stored = Array(stored.suffix(cap)) }
        UserDefaults.standard.set(stored, forKey: key)
    }
}
