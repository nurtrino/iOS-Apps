import UIKit

/// Bounds how many image requests are in flight.
///
/// A fast scroll through a grid asks for a hundred thumbnails in a couple of
/// seconds. Unbounded, that exhausts the connection pool and every request gets
/// slower than if they had simply queued.
actor ConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot straight to the next waiter rather than
            // decrementing and letting a newcomer barge in.
            waiting.removeFirst().resume()
        }
    }
}

/// Thumbnails and avatars.
actor ImageLoader {

    static let shared = ImageLoader()

    private let session: URLSession
    private let gate = ConcurrencyGate(limit: 6)
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    private let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(
                memoryCapacity: 32 * 1024 * 1024,
                diskCapacity: 256 * 1024 * 1024,
                diskPath: "vela-images"
            )
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    /// An already-decoded image, so a cell can draw on its first frame instead
    /// of flashing a placeholder.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> UIImage {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<UIImage, Error> { [weak self] in
            guard let self else { throw APIError.cancelled }
            return try await self.download(url)
        }
        inFlight[url] = task

        do {
            let image = try await task.value
            inFlight[url] = nil
            return image
        } catch {
            inFlight[url] = nil
            throw APIError.from(error)
        }
    }

    /// Load from a file already on disk — the poster frame kept beside a
    /// download, so the offline library renders with no network at all.
    func localImage(at url: URL) -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    private func download(_ url: URL) async throws -> UIImage {
        await gate.acquire()
        defer { Task { await gate.release() } }

        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw http.statusCode == 404 ? APIError.notFound : APIError.server(http.statusCode)
        }
        guard let image = UIImage(data: data) else { throw APIError.malformedResponse }

        // Decode off the main thread now rather than during the frame that
        // first displays it — the difference between a smooth grid and a
        // stutter on every new row.
        let ready = await image.byPreparingForDisplay() ?? image
        memory.setObject(ready, forKey: url as NSURL, cost: data.count)
        return ready
    }

    func clearCache() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}
