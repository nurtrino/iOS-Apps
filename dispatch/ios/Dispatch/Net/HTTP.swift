import Foundation

/// The one place a request goes out.
///
/// Two details here are load-bearing rather than decorative:
///
/// **The User-Agent.** `URLSession`'s default is `AppName/1 CFNetwork/... Darwin/...`,
/// and a meaningful share of news hosts — Cloudflare in front of a WordPress
/// install, mostly — answer that with a 403. Sending a browser string is what
/// makes several of the built-in sources reachable at all.
///
/// **The concurrency gate.** A "Top" refresh asks every source at once, and a
/// Steam library refresh asks for news per game. Unbounded, that opens dozens
/// of sockets and every request gets slower than if they had simply queued.
actor HTTP {

    static let shared = HTTP()

    private let session: URLSession
    private let gate = ConcurrencyGate(limit: 6)

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(
                memoryCapacity: 8 * 1024 * 1024,
                diskCapacity: 64 * 1024 * 1024,
                diskPath: "dispatch-http"
            )
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 45
            configuration.httpAdditionalHeaders = [
                "User-Agent": HTTP.userAgent,
                "Accept-Language": "en-US,en;q=0.9",
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Fetches a URL, throwing a `FeedError` rather than a raw `URLError`.
    ///
    /// `accept` is sent as-is. It matters for the RSS hosts that content
    /// negotiate: ask for `*/*` and some return the HTML page instead of the
    /// feed at the same address.
    func data(from url: URL, accept: String, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        await gate.acquire()
        defer { Task { await gate.release() } }

        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.cachePolicy = cachePolicy

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedError.from(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FeedError.empty }
        return data
    }

    /// Feeds and the Telegram preview page want different `Accept` headers, so
    /// these exist rather than every caller remembering which.
    func feedData(from url: URL) async throws -> Data {
        try await data(
            from: url,
            accept: "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.8"
        )
    }

    func htmlData(from url: URL) async throws -> Data {
        try await data(from: url, accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8")
    }

    func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await data(from: url, accept: "application/json")
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FeedError.notAFeed
        }
    }
}

/// Bounds how many requests are in flight.
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
