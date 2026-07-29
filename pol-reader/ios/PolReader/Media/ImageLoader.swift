import UIKit

/// Bounds how many things may happen at once.
///
/// Thumbnails are the one place this app can genuinely fan out: a fast scroll
/// through a catalog grid asks for a hundred images in a second or two.
/// Unbounded, that exhausts the connection pool and every request gets slower
/// than if they had queued.
actor ConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        if waiting.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot straight to the next waiter rather than decrementing
            // and letting it re-check, which would let a newcomer barge in.
            waiting.removeFirst().resume()
        }
    }
}

/// Loads and caches post images and thumbnails.
///
/// Separate from `ChanAPI` on purpose: the one-request-per-second rule applies
/// to the JSON API on `a.4cdn.org`, not to media on `i.4cdn.org`. Pacing
/// thumbnails at that rate would make the catalog unusable.
actor ImageLoader {

    static let shared = ImageLoader()

    private let session: URLSession
    private let gate = ConcurrencyGate(limit: 6)
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    private let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
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
                diskPath: "chan-media"
            )
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    /// A cached image, if one is already in memory. Lets a view show something
    /// on the very first frame instead of flashing a placeholder.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> UIImage {
        if let hit = memory.object(forKey: url as NSURL) { return hit }

        if let existing = inFlight[url] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> { [weak self] in
            guard let self else { throw ChanError.cancelled }
            return try await self.download(url)
        }
        inFlight[url] = task

        do {
            let image = try await task.value
            inFlight[url] = nil
            return image
        } catch {
            inFlight[url] = nil
            throw ChanError.from(error)
        }
    }

    /// The bytes of a media file, for the things a `UIImage` cannot represent.
    ///
    /// Two callers: an animated GIF, whose frames the animator reads itself
    /// (`UIImage` would keep only the first), and saving to Photos, which wants
    /// the original file rather than a re-encode of a decoded frame.
    ///
    /// Deliberately not held in the image cache. `URLCache` on this session
    /// already keeps the response in memory and on disk, so a second copy of a
    /// multi-megabyte file would buy nothing.
    func data(for url: URL) async throws -> Data {
        await gate.acquire()
        defer { Task { await gate.release() } }

        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 404 ? ChanError.notFound : ChanError.server(http.statusCode)
            }
            return data
        } catch {
            throw ChanError.from(error)
        }
    }

    private func download(_ url: URL) async throws -> UIImage {
        await gate.acquire()
        defer { Task { await gate.release() } }

        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 404 ? ChanError.notFound : ChanError.server(http.statusCode)
        }
        guard let image = UIImage(data: data) else {
            throw ChanError.malformedResponse
        }

        // Decode off the main thread now, rather than during the first frame
        // that displays it. This is the difference between a smooth catalog
        // scroll and a stutter on every new row.
        let ready = await image.byPreparingForDisplay() ?? image
        memory.setObject(ready, forKey: url as NSURL, cost: data.count)
        return ready
    }

    func clearCache() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}
