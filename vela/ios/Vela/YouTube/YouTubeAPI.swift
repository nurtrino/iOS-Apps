import Foundation

/// Client for the YouTube Data API v3.
///
/// Built against the published discovery document (revision 20260728). Worth
/// stating plainly, because it shapes the whole app: **this API returns
/// metadata and an embed, never a stream**. There is no `streamingData`, no
/// adaptive format list and no file URL anywhere in its schema. So YouTube
/// videos here are browsed natively and played in YouTube's own player, and the
/// download, background-audio and Picture-in-Picture features belong to the
/// PeerTube source, where the server hands out an actual file.
///
/// Quota is the other thing that shapes it. A key gets 10,000 units a day by
/// default and `search.list` costs 100 of them, so a hundred searches exhausts
/// it. `videos.list`, `channels.list` and `playlistItems.list` cost 1 each.
/// Every method below notes its cost, and the app prefers the cheap ones
/// wherever the same screen can be built from either.
actor YouTubeAPI {

    static let shared = YouTubeAPI()

    private static let base = URL(string: "https://www.googleapis.com/youtube/v3/")!

    private var apiKey: String?
    private let session: URLSession
    /// Spent units, best-effort and local. The API does not report remaining
    /// quota, so this is the app's own tally — accurate for what this device
    /// spent today, blind to the same key used elsewhere.
    private(set) var spentUnits = 0
    private var tallyDay: Int?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func use(apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var hasKey: Bool { apiKey != nil }

    // MARK: - Feeds

    /// Trending, at 1 unit.
    ///
    /// `chart=mostPopular` rather than a search sorted by view count: the chart
    /// is what YouTube actually promotes, and it costs a hundredth as much.
    func trending(regionCode: String, pageToken: String? = nil,
                  count: Int = 25) async throws -> YouTubePage<YouTubeVideo> {
        try await get(
            "videos",
            query: [
                "part": "snippet,contentDetails,statistics",
                "chart": "mostPopular",
                "regionCode": regionCode,
                "maxResults": String(count),
                "pageToken": pageToken,
            ],
            cost: 1
        )
    }

    /// Full detail for specific videos, at 1 unit for the whole batch.
    ///
    /// Search results arrive without duration or view counts, so a page of them
    /// is enriched with a single call here rather than one per row.
    func videos(ids: [String]) async throws -> [YouTubeVideo] {
        guard !ids.isEmpty else { return [] }
        // The endpoint caps a batch at 50 ids.
        let batches = stride(from: 0, to: ids.count, by: 50).map {
            Array(ids[$0..<min($0 + 50, ids.count)])
        }
        var collected: [YouTubeVideo] = []
        for batch in batches {
            let page: YouTubePage<YouTubeVideo> = try await get(
                "videos",
                query: [
                    "part": "snippet,contentDetails,statistics",
                    "id": batch.joined(separator: ","),
                    "maxResults": "50",
                ],
                cost: 1
            )
            collected.append(contentsOf: page.items)
        }
        return collected
    }

    /// Search, at 100 units — the expensive one.
    ///
    /// Returns results without durations; call `videos(ids:)` to fill them in
    /// for one more unit, which is why the store does exactly that rather than
    /// leaving the rows bare.
    func search(_ query: String, order: YouTubeSearchOrder = .relevance,
                pageToken: String? = nil,
                count: Int = 25) async throws -> YouTubePage<YouTubeVideo> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        return try await get(
            "search",
            query: [
                "part": "snippet",
                "q": trimmed,
                "type": "video",
                "order": order.rawValue,
                "maxResults": String(count),
                "pageToken": pageToken,
            ],
            cost: 100
        )
    }

    /// A channel by id, at 1 unit.
    func channel(id: String) async throws -> YouTubeChannel {
        let page: YouTubePage<YouTubeChannel> = try await get(
            "channels",
            query: ["part": "snippet,statistics,contentDetails", "id": id],
            cost: 1
        )
        guard let channel = page.items.first else { throw APIError.notFound }
        return channel
    }

    /// A channel by its `@handle`, at 1 unit.
    func channel(handle: String) async throws -> YouTubeChannel {
        let normalised = handle.hasPrefix("@") ? handle : "@\(handle)"
        let page: YouTubePage<YouTubeChannel> = try await get(
            "channels",
            query: ["part": "snippet,statistics,contentDetails", "forHandle": normalised],
            cost: 1
        )
        guard let channel = page.items.first else { throw APIError.notFound }
        return channel
    }

    /// A playlist's contents, at 1 unit.
    ///
    /// This is how a channel's videos are listed: every channel has an uploads
    /// playlist, and reading it costs 1 unit where `search?channelId=` costs
    /// 100 for the same thing.
    func playlistItems(playlistID: String, pageToken: String? = nil,
                       count: Int = 25) async throws -> YouTubePage<YouTubeVideo> {
        try await get(
            "playlistItems",
            query: [
                "part": "snippet,contentDetails",
                "playlistId": playlistID,
                "maxResults": String(count),
                "pageToken": pageToken,
            ],
            cost: 1
        )
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [String: String?],
                                   cost: Int) async throws -> T {
        guard let apiKey else { throw APIError.missingAPIKey }

        guard var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else {
            throw APIError.malformedResponse
        }

        var items = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        items.append(URLQueryItem(name: "key", value: apiKey))
        // Stable ordering keeps requests comparable in a log or a proxy.
        components.queryItems = items.sorted { $0.name < $1.name }

        guard let url = components.url else { throw APIError.malformedResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.from(error)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }

        switch http.statusCode {
        case 200...299:
            recordSpend(cost)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.malformedResponse
            }
        case 400:
            // A malformed key comes back as 400 with `keyInvalid`, which is a
            // different fix from a 403 and should not read as "quota spent".
            throw Self.reason(in: data) == "keyInvalid" ? .missingAPIKey : .server(400)
        case 403:
            // 403 covers both a spent quota and a key restricted to other
            // referrers. Only the body distinguishes them.
            switch Self.reason(in: data) {
            case "quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded":
                recordSpend(cost)
                throw APIError.quotaExceeded
            default:
                throw APIError.unauthorized
            }
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.server(http.statusCode)
        }
    }

    /// Pulls `error.errors[0].reason` out of a Google API error body.
    private static func reason(in data: Data) -> String? {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                struct Entry: Decodable { let reason: String? }
                let errors: [Entry]?
            }
            let error: Payload?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?
            .error?.errors?.first?.reason
    }

    // MARK: - Quota tally

    /// Rolls the tally over at the start of a new day.
    ///
    /// Quota resets at midnight Pacific rather than local midnight, so this is
    /// an approximation deliberately: it exists to warn somebody they are
    /// burning through searches, not to be an accounting record.
    private func recordSpend(_ cost: Int) {
        let today = Calendar.current.ordinality(of: .day, in: .era, for: Date())
        if tallyDay != today {
            tallyDay = today
            spentUnits = 0
        }
        spentUnits += cost
    }

    func resetTally() {
        spentUnits = 0
        tallyDay = Calendar.current.ordinality(of: .day, in: .era, for: Date())
    }
}

/// Sort orders worth exposing. The API also accepts `title` and `videoCount`,
/// which are meaningless for a video search.
enum YouTubeSearchOrder: String, CaseIterable, Identifiable {
    case relevance
    case date
    case viewCount
    case rating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .date: return "Newest"
        case .viewCount: return "Most viewed"
        case .rating: return "Top rated"
        }
    }
}
