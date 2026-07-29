import Foundation

/// JSON documents in Application Support.
///
/// Everything this app persists is small, local and disposable — the source
/// list, read state, saved articles, and a cached copy of each feed. None of it
/// leaves the device and none of it is worth a database.
enum DiskStore {

    private static let directoryName = "Dispatch"

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func url(for name: String) -> URL? {
        // A source id becomes part of a filename, and a user-added source can
        // be called anything. Sanitising here rather than at each call site is
        // what stops an id containing "/" from writing outside the directory.
        let safe = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        return directory?
            .appendingPathComponent(String(safe))
            .appendingPathExtension("json")
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = url(for: name),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let url = url(for: name),
              let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete(_ name: String) {
        guard let url = url(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Total bytes held by the caches, for the line in Settings that offers to
    /// clear them.
    static func cacheSize() -> Int64 {
        guard let directory else { return 0 }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var total: Int64 = 0
        for name in names where name.hasPrefix(FeedCache.prefix) {
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? Int64) ?? 0
        }
        return total
    }

    static func clearFeedCaches() {
        guard let directory else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasPrefix(FeedCache.prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// The last good copy of one source's articles.
///
/// This is what makes a cold launch show news instead of six spinners. The feed
/// on disk goes on screen immediately and the network refresh replaces it when
/// it lands — and if the network is not there at all, yesterday's news beats an
/// error page.
struct FeedCache: Codable {
    static let prefix = "feed-"

    var articles: [Article]
    var fetched: Date
    var note: String?

    static func load(sourceID: String) -> FeedCache? {
        DiskStore.load(FeedCache.self, from: prefix + sourceID)
    }

    func save(sourceID: String) {
        DiskStore.save(self, to: FeedCache.prefix + sourceID)
    }

    static func delete(sourceID: String) {
        DiskStore.delete(prefix + sourceID)
    }
}

/// Collapses a burst of writes into one.
///
/// Scrolling a section marks a screenful of articles read, which fires a change
/// per row. Without this that is a file write per row; with it, one write
/// shortly after the scroll stops. `flush()` exists so the app can force the
/// pending write out when it goes to the background rather than losing it.
@MainActor
final class DebouncedWriter {

    private let delay: TimeInterval
    private var pending: (() -> Void)?
    private var task: Task<Void, Never>?

    init(delay: TimeInterval = 0.5) {
        self.delay = delay
    }

    func schedule(_ work: @escaping () -> Void) {
        pending = work
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        pending?()
        pending = nil
    }
}
