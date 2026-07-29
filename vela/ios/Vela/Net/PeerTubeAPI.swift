import Foundation

/// Client for one PeerTube instance.
///
/// An actor because it owns mutable session state — the instance, the access
/// token and the refresh token — that every screen reads concurrently. The
/// interesting behaviour is token refresh: a 401 triggers exactly one refresh
/// attempt and one retry, and concurrent callers share that single refresh
/// rather than each firing their own and invalidating each other's rotation.
actor PeerTubeAPI {

    static let shared = PeerTubeAPI()

    private let session: URLSession
    private let decoder = JSONDecoder()

    private var instance: Instance?
    private var accessToken: String?
    private var refreshToken: String?
    /// PeerTube issues per-instance OAuth client credentials, fetched once.
    private var clientID: String?
    private var clientSecret: String?

    /// The in-flight refresh, so simultaneous 401s wait on one rotation.
    /// Refresh tokens are single-use: two parallel refreshes mean the second
    /// presents a token the first already consumed, and the session dies.
    private var refreshTask: Task<Bool, Never>?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 128 * 1024 * 1024,
                diskPath: "vela-api"
            )
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Session state

    func use(instance: Instance) {
        guard instance != self.instance else { return }
        self.instance = instance
        // Client credentials and tokens belong to the instance that issued
        // them; carrying them across would authenticate nothing.
        clientID = nil
        clientSecret = nil
        accessToken = nil
        refreshToken = nil
    }

    func currentInstance() -> Instance? { instance }

    func restore(accessToken: String?, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
    }

    var isSignedIn: Bool { accessToken != nil }

    // MARK: - Public endpoints

    func config() async throws -> InstanceConfig {
        try await get("config", authenticated: false)
    }

    func videos(sort: VideoSort, start: Int, count: Int,
                includeNSFW: Bool) async throws -> Page<Video> {
        try await get("videos", authenticated: false, query: [
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "nsfw", value: includeNSFW ? "both" : "false"),
        ])
    }

    func search(_ query: String, sort: VideoSort, start: Int, count: Int,
                includeNSFW: Bool) async throws -> Page<Video> {
        try await get("search/videos", authenticated: false, query: [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "nsfw", value: includeNSFW ? "both" : "false"),
        ])
    }

    /// A single video. Accepts a UUID, short UUID or numeric id — PeerTube
    /// resolves all three on this route.
    func video(id: String) async throws -> VideoDetails {
        try await get("videos/\(id)", authenticated: false)
    }

    func channelVideos(handle: String, start: Int, count: Int) async throws -> Page<Video> {
        try await get("video-channels/\(handle)/videos", authenticated: false, query: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "sort", value: VideoSort.recent.rawValue),
        ])
    }

    // MARK: - Authenticated endpoints

    func me() async throws -> CurrentUser {
        try await get("users/me", authenticated: true)
    }

    func subscriptionVideos(start: Int, count: Int) async throws -> Page<Video> {
        try await get("users/me/subscriptions/videos", authenticated: true, query: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "sort", value: VideoSort.recent.rawValue),
        ])
    }

    // MARK: - Sign in

    /// Exchange a username and password for tokens.
    ///
    /// This is PeerTube's own password grant against the instance the reader
    /// chose. The password is used for this one request and never stored;
    /// only the returned tokens are kept, in the Keychain.
    func signIn(username: String, password: String) async throws -> StoredSession {
        let credentials = try await oauthClient()

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.id),
            URLQueryItem(name: "client_secret", value: credentials.secret),
            URLQueryItem(name: "grant_type", value: "password"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]

        let token: TokenResponse = try await postForm("users/token", body: body)
        accessToken = token.accessToken
        refreshToken = token.refreshToken
        return StoredSession(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
        )
    }

    private func oauthClient() async throws -> (id: String, secret: String) {
        if let clientID, let clientSecret { return (clientID, clientSecret) }
        let response: OAuthClientResponse = try await get("oauth-clients/local", authenticated: false)
        clientID = response.clientID
        clientSecret = response.clientSecret
        return (response.clientID, response.clientSecret)
    }

    /// Rotate the tokens. Returns false when the session is unrecoverable.
    private func performRefresh() async -> Bool {
        guard let refreshToken, let credentials = try? await oauthClient() else { return false }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.id),
            URLQueryItem(name: "client_secret", value: credentials.secret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]

        guard let token: TokenResponse = try? await postForm("users/token", body: body) else {
            // The refresh token is spent or revoked; nothing to do but sign out.
            self.accessToken = nil
            self.refreshToken = nil
            return false
        }

        accessToken = token.accessToken
        self.refreshToken = token.refreshToken
        await SessionKeychain.shared.save(
            StoredSession(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
            )
        )
        return true
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ endpoint: String,
                                   authenticated: Bool,
                                   query: [URLQueryItem] = []) async throws -> T {
        guard let instance, let url = instance.apiURL(endpoint, query: query) else {
            throw APIError.noInstance
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await send(request, authenticated: authenticated)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.malformedResponse
        }
    }

    private func postForm<T: Decodable>(_ endpoint: String, body: URLComponents) async throws -> T {
        guard let instance, let url = instance.apiURL(endpoint) else { throw APIError.noInstance }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // `query` percent-encodes each value correctly; the body is that same
        // encoding without the leading question mark.
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let data = try await send(request, authenticated: false, allowRefresh: false)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.malformedResponse
        }
    }

    private func send(_ request: URLRequest,
                      authenticated: Bool,
                      allowRefresh: Bool = true) async throws -> Data {
        var request = request
        if authenticated {
            guard let accessToken else { throw APIError.unauthorized }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }

        switch http.statusCode {
        case 200...299:
            return data

        case 401 where authenticated && allowRefresh:
            guard await refreshIfNeeded() else { throw APIError.unauthorized }
            // One retry, with `allowRefresh` off so a server that answers 401
            // to a freshly minted token cannot start a refresh loop.
            return try await send(request, authenticated: true, allowRefresh: false)

        case 401, 403:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.server(http.statusCode)
        }
    }

    /// Join the in-flight refresh if there is one, otherwise start it.
    private func refreshIfNeeded() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let task = Task<Bool, Never> { await self.performRefresh() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }
}

// MARK: - Wire types

private struct OAuthClientResponse: Decodable {
    let clientID: String
    let clientSecret: String

    private enum CodingKeys: String, CodingKey {
        case client_id, client_secret
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try c.decode(String.self, forKey: .client_id)
        clientSecret = try c.decode(String.self, forKey: .client_secret)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case access_token, refresh_token, expires_in
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .access_token)
        refreshToken = (try? c.decode(String.self, forKey: .refresh_token)) ?? ""
        expiresIn = c.lenientInt(.expires_in)
    }
}
