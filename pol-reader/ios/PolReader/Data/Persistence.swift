import Foundation

/// JSON documents in Application Support.
///
/// Everything this app persists is small, local, and disposable — watched
/// threads, read state, filters. None of it leaves the device, and none of it
/// is worth a database.
enum DiskStore {

    private static let directoryName = "PolReader"

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
        directory?.appendingPathComponent(name).appendingPathExtension("json")
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
}

/// Collapses a burst of writes into one.
///
/// Marking a screenful of threads read fires a change per row. Without this,
/// that is a file write per row; with it, one write shortly after the scroll
/// stops. `flush()` exists so the app can force the pending write out when it
/// goes to the background rather than losing it.
@MainActor
final class DebouncedWriter {

    private let delay: TimeInterval
    private var pending: (() -> Void)?
    private var task: Task<Void, Never>?

    init(delay: TimeInterval = 0.4) {
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
        let work = pending
        pending = nil
        work?()
    }
}
