import UIKit

/// Article thumbnails and inline images.
///
/// News images come from wherever the publisher hosts them, and a fair number
/// of those hosts also reject the default `URLSession` user agent — so this
/// carries the same browser string as `HTTP`, for the same reason.
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
                diskPath: "dispatch-images"
            )
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.timeoutIntervalForRequest = 30
            configuration.httpAdditionalHeaders = ["User-Agent": HTTP.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    /// An already-decoded image, so a row can draw on its first frame instead
    /// of flashing a placeholder.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> UIImage {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        // Deduplicating in-flight requests matters more here than in most apps:
        // the same image appears in a section, in Top, and in search results,
        // and all three ask for it in the same frame.
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<UIImage, Error> { [weak self] in
            guard let self else { throw FeedError.transport("Cancelled.") }
            return try await self.download(url)
        }
        inFlight[url] = task

        do {
            let image = try await task.value
            inFlight[url] = nil
            return image
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    private func download(_ url: URL) async throws -> UIImage {
        await gate.acquire()
        defer { Task { await gate.release() } }

        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        guard let image = UIImage(data: data) else { throw FeedError.notAFeed }

        // Decode off the main thread now rather than during the frame that
        // first displays it — the difference between a smooth list and a
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
