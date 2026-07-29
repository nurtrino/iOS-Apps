import Foundation

/// Client for `a.4cdn.org`.
///
/// 4chan's API documentation asks for three things, and all three shape this
/// type more than anything else does:
///
///   - "Do not make more than one request per second."
///   - "Thread updating should be set to a minimum of 10 seconds."
///   - "Use If-Modified-Since when doing your requests."
///
/// So this is not the usual bounded-concurrency batch fetcher. There is nothing
/// to fan out over — a whole thread arrives in one response — and the scarce
/// resource is *request slots over time*, not sockets. The interesting parts
/// are therefore the pacer and the conditional-request cache.
actor ChanAPI {

    static let shared = ChanAPI()

    private static let host = "https://a.4cdn.org"

    /// The site asks for no more than one request per second.
    private let minimumRequestInterval: TimeInterval = 1.0

    private let session: URLSession
    private let decoder = JSONDecoder()

    /// The next instant a request may be sent. Reserved *before* suspending, so
    /// two callers arriving together take consecutive slots rather than both
    /// reading the same "last request" time and firing at once.
    private var nextAllowedRequest = Date.distantPast

    /// In-flight requests by URL, so that a screen appearing while a refresh is
    /// already running joins that request instead of issuing a second one.
    private var inFlight: [String: Task<Data, Error>] = [:]

    /// Last-Modified and the body it belongs to, per URL. Kept explicitly
    /// rather than leaning on `URLCache` revalidation: 4chan sends no
    /// `Cache-Control`, so URLSession's heuristics decide when to revalidate,
    /// and the documentation is specific about wanting If-Modified-Since.
    private var conditional: [String: ConditionalEntry] = [:]

    private struct ConditionalEntry {
        let lastModified: String?
        let data: Data
        var storedAt: Date
    }

    /// A handful of endpoints — the catalog, a few open threads — is all this
    /// ever needs to hold.
    private let conditionalLimit = 24

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Disk-backed cache: free offline-ish behaviour on relaunch, and it
            // also serves the image loader, which shares this configuration's
            // sibling in `ImageLoader`.
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 128 * 1024 * 1024,
                diskPath: "chan-api"
            )
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Endpoints

    /// The board catalog: every page, every OP, a few preview replies each.
    ///
    /// One request for the entire board. There is no pagination behind
    /// scrolling — the list view paginates purely to bound render cost.
    func catalog(board: String, forceRefresh: Bool = false) async throws -> [CatalogPage] {
        try await get("/\(board)/catalog.json", as: [CatalogPage].self, forceRefresh: forceRefresh)
    }

    /// A complete thread in a single request.
    ///
    /// This endpoint is why this app has no partially-loaded thread state, no
    /// per-comment fetch queue, and no search-index fallback: there is nothing
    /// to assemble.
    func thread(board: String, no: Int, forceRefresh: Bool = false) async throws -> ThreadResponse {
        try await get("/\(board)/thread/\(no).json", as: ThreadResponse.self, forceRefresh: forceRefresh)
    }

    /// Thread numbers and modification times only — cheap enough to poll for
    /// "is this thread still alive?" without pulling the whole thing.
    func threadList(board: String, forceRefresh: Bool = false) async throws -> [ThreadListPage] {
        try await get("/\(board)/threads.json", as: [ThreadListPage].self, forceRefresh: forceRefresh)
    }

    /// Post numbers of threads that have fallen into the board archive.
    func archive(board: String, forceRefresh: Bool = false) async throws -> [Int] {
        try await get("/\(board)/archive.json", as: [Int].self, forceRefresh: forceRefresh)
    }

    func boards(forceRefresh: Bool = false) async throws -> [Board] {
        try await get("/boards.json", as: BoardsResponse.self, forceRefresh: forceRefresh).boards
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, as type: T.Type, forceRefresh: Bool) async throws -> T {
        guard let url = URL(string: Self.host + path) else {
            throw ChanError.malformedResponse
        }
        let data = try await data(for: url, forceRefresh: forceRefresh)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ChanError.malformedResponse
        }
    }

    private func data(for url: URL, forceRefresh: Bool) async throws -> Data {
        let key = url.absoluteString

        // Join an identical request already running. This applies to
        // force-refresh too: a pull-to-refresh landing mid-flight wants the
        // result that is already on its way, not a second round trip.
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<Data, Error> { [weak self] in
            guard let self else { throw ChanError.cancelled }
            return try await self.load(key: key, url: url, forceRefresh: forceRefresh)
        }
        inFlight[key] = task

        do {
            let data = try await task.value
            inFlight[key] = nil
            return data
        } catch {
            inFlight[key] = nil
            throw ChanError.from(error)
        }
    }

    private func load(key: String, url: URL, forceRefresh: Bool) async throws -> Data {
        await pace()

        var request = URLRequest(url: url)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

        // A conditional request is *not* skipped on force-refresh: revalidating
        // is the cheap path, and a 304 there is a correct answer meaning
        // "nothing new", not a stale one.
        let cached = conditional[key]
        if let stamp = cached?.lastModified {
            request.setValue(stamp, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw ChanError.malformedResponse
        }

        switch http.statusCode {
        case 200:
            store(key: key,
                  lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                  data: data)
            return data

        case 304:
            if let cached {
                return cached.data
            }
            // A 304 with nothing cached means our bookkeeping and URLSession's
            // disagree. Ask once more unconditionally rather than failing.
            conditional[key] = nil
            var retry = URLRequest(url: url)
            retry.cachePolicy = .reloadIgnoringLocalCacheData
            await pace()
            let (retryData, retryResponse) = try await session.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse, retryHTTP.statusCode == 200 else {
                throw ChanError.malformedResponse
            }
            store(key: key,
                  lastModified: retryHTTP.value(forHTTPHeaderField: "Last-Modified"),
                  data: retryData)
            return retryData

        case 404:
            // Threads 404 as a matter of course when they fall off the board.
            // Drop any cached body so a stale copy cannot resurface.
            conditional[key] = nil
            throw ChanError.notFound

        case 429:
            throw ChanError.rateLimited

        default:
            throw ChanError.server(http.statusCode)
        }
    }

    /// Reserve the next request slot, then wait for it.
    ///
    /// The reservation happens before the suspension point, which is the whole
    /// trick: concurrent callers each take a distinct slot instead of all
    /// reading the same timestamp and firing simultaneously.
    private func pace() async {
        let now = Date()
        let scheduled = max(now, nextAllowedRequest)
        nextAllowedRequest = scheduled.addingTimeInterval(minimumRequestInterval)

        let delay = scheduled.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func store(key: String, lastModified: String?, data: Data) {
        conditional[key] = ConditionalEntry(lastModified: lastModified, data: data, storedAt: Date())
        guard conditional.count > conditionalLimit else { return }
        // Evict oldest first. The working set is a catalog plus a few threads,
        // so this never runs hot enough to want a real LRU.
        let sorted = conditional.sorted { $0.value.storedAt < $1.value.storedAt }
        for (staleKey, _) in sorted.prefix(conditional.count - conditionalLimit) {
            conditional.removeValue(forKey: staleKey)
        }
    }

    /// Drop all conditional bookkeeping — used when the reader explicitly asks
    /// for a clean reload after something looked wrong.
    func resetCache() {
        conditional.removeAll()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}
