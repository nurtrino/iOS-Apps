import Foundation

/// A video as YouTube describes it.
///
/// One type covers three endpoints that describe the same thing differently:
/// `search.list` returns `id` as `{ kind, videoId }` and carries no duration or
/// statistics; `videos.list` returns `id` as a bare string and can carry both;
/// `playlistItems.list` buries the video id in `snippet.resourceId.videoId`.
/// Normalising here keeps that shape difference out of every list in the app.
struct YouTubeVideo: Identifiable, Equatable {

    let id: String
    let title: String
    let channelID: String?
    let channelTitle: String?
    let publishedAt: Date?
    let thumbnailURL: URL?
    /// Absent from search results — those cost 100 quota units and still do not
    /// carry it, so a list built from search shows no duration until the far
    /// cheaper `videos.list` fills it in.
    let durationSeconds: Int?
    let viewCount: Int?
    let isLive: Bool

    var durationLabel: String { ISO8601Duration.label(durationSeconds) }

    /// Watching happens in YouTube's own player, so the only URL the app ever
    /// needs is the canonical watch page — used for handoff and sharing.
    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(id)")
    }
}

extension YouTubeVideo: Decodable {

    private enum Key: String, CodingKey {
        case id, snippet, contentDetails, statistics
    }

    private enum IDKey: String, CodingKey {
        case videoId
    }

    private enum SnippetKey: String, CodingKey {
        case title, channelId, channelTitle, publishedAt, thumbnails
        case liveBroadcastContent, resourceId
    }

    private enum ContentKey: String, CodingKey {
        case duration
    }

    private enum StatisticsKey: String, CodingKey {
        case viewCount
    }

    private enum ResourceKey: String, CodingKey {
        case videoId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let snippet = try? container.nestedContainer(keyedBy: SnippetKey.self, forKey: .snippet)

        // Three spellings of the same identifier, in the order the endpoints
        // that produce them are most likely to be hit.
        var resolved = container.lenientNonEmptyString(.id)
        if resolved == nil,
           let nested = try? container.nestedContainer(keyedBy: IDKey.self, forKey: .id) {
            resolved = nested.lenientNonEmptyString(.videoId)
        }
        if resolved == nil, let snippet,
           let resource = try? snippet.nestedContainer(keyedBy: ResourceKey.self, forKey: .resourceId) {
            resolved = resource.lenientNonEmptyString(.videoId)
        }

        guard let id = resolved else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "No video id in any of the three shapes the API uses"
            )
        }
        self.id = id

        title = snippet?.lenientNonEmptyString(.title) ?? "Untitled"
        channelID = snippet?.lenientNonEmptyString(.channelId)
        channelTitle = snippet?.lenientNonEmptyString(.channelTitle)
        publishedAt = snippet?.lenientDate(.publishedAt)
        thumbnailURL = snippet.flatMap { YouTubeThumbnails.best(in: $0, forKey: .thumbnails) }

        // "live" while broadcasting, "upcoming" before it starts, "none"
        // otherwise. Deleted videos in a playlist carry no snippet at all.
        isLive = snippet?.lenientNonEmptyString(.liveBroadcastContent) == "live"

        let content = try? container.nestedContainer(keyedBy: ContentKey.self, forKey: .contentDetails)
        durationSeconds = ISO8601Duration.seconds(from: content?.lenientNonEmptyString(.duration))

        let statistics = try? container.nestedContainer(
            keyedBy: StatisticsKey.self, forKey: .statistics
        )
        // Counts arrive as strings, and are absent entirely when the uploader
        // has hidden them.
        viewCount = statistics?.lenientInt(.viewCount)
    }
}

/// A channel.
struct YouTubeChannel: Identifiable, Equatable {
    let id: String
    let title: String
    let channelDescription: String?
    let thumbnailURL: URL?
    let subscriberCount: Int?
    let videoCount: Int?
    /// The playlist holding everything the channel has uploaded. Listing this
    /// costs 1 quota unit against `search.list`'s 100, and is the reason the
    /// channel screen is affordable at all.
    let uploadsPlaylistID: String?
}

extension YouTubeChannel: Decodable {

    private enum Key: String, CodingKey {
        case id, snippet, statistics, contentDetails
    }

    private enum SnippetKey: String, CodingKey {
        case title, description, thumbnails
    }

    private enum StatisticsKey: String, CodingKey {
        case subscriberCount, videoCount, hiddenSubscriberCount
    }

    private enum ContentKey: String, CodingKey {
        case relatedPlaylists
    }

    private enum RelatedKey: String, CodingKey {
        case uploads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)

        guard let id = container.lenientNonEmptyString(.id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "No channel id"
            )
        }
        self.id = id

        let snippet = try? container.nestedContainer(keyedBy: SnippetKey.self, forKey: .snippet)
        title = snippet?.lenientNonEmptyString(.title) ?? "Unknown channel"
        channelDescription = snippet?.lenientNonEmptyString(.description)
        thumbnailURL = snippet.flatMap { YouTubeThumbnails.best(in: $0, forKey: .thumbnails) }

        let statistics = try? container.nestedContainer(
            keyedBy: StatisticsKey.self, forKey: .statistics
        )
        // A hidden subscriber count still reports a number — zero — so the flag
        // has to be honoured or the channel appears to have no subscribers.
        let hidden = statistics?.lenientBool(.hiddenSubscriberCount) ?? false
        subscriberCount = hidden ? nil : statistics?.lenientInt(.subscriberCount)
        videoCount = statistics?.lenientInt(.videoCount)

        let content = try? container.nestedContainer(keyedBy: ContentKey.self, forKey: .contentDetails)
        let related = content.flatMap {
            try? $0.nestedContainer(keyedBy: RelatedKey.self, forKey: .relatedPlaylists)
        }
        uploadsPlaylistID = related?.lenientNonEmptyString(.uploads)
    }
}

/// Picks a thumbnail from the `thumbnails` object.
///
/// The API returns up to five named sizes and guarantees none of them beyond
/// `default`. Rather than decode all five into a struct nothing reads, this
/// walks them largest-first and takes the first that is actually present.
enum YouTubeThumbnails {

    private enum SizeKey: String, CodingKey {
        case maxres, standard, high, medium, `default`
    }

    private enum ThumbnailKey: String, CodingKey {
        case url
    }

    /// Largest first: these are poster frames behind a card, and the medium
    /// size is visibly soft on a modern display.
    private static let preference: [SizeKey] = [.maxres, .standard, .high, .medium, .default]

    static func best<K: CodingKey>(in container: KeyedDecodingContainer<K>, forKey key: K) -> URL? {
        guard let sizes = try? container.nestedContainer(keyedBy: SizeKey.self, forKey: key) else {
            return nil
        }
        for size in preference {
            guard let entry = try? sizes.nestedContainer(keyedBy: ThumbnailKey.self, forKey: size),
                  let raw = entry.lenientNonEmptyString(.url),
                  let url = URL(string: raw) else { continue }
            return url
        }
        return nil
    }
}

/// One page of results.
///
/// Items are decoded individually so a single malformed entry — a deleted video
/// still listed in a playlist, most commonly — drops that row instead of
/// emptying the page.
struct YouTubePage<Item: Decodable>: Decodable {

    let items: [Item]
    let nextPageToken: String?
    let totalResults: Int?

    private enum Key: String, CodingKey {
        case items, nextPageToken, pageInfo
    }

    private enum PageInfoKey: String, CodingKey {
        case totalResults
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        nextPageToken = container.lenientNonEmptyString(.nextPageToken)

        let info = try? container.nestedContainer(keyedBy: PageInfoKey.self, forKey: .pageInfo)
        totalResults = info?.lenientInt(.totalResults)

        var decoded: [Item] = []
        if var array = try? container.nestedUnkeyedContainer(forKey: .items) {
            while !array.isAtEnd {
                if let item = try? array.decode(Item.self) {
                    decoded.append(item)
                } else {
                    // Consume the slot regardless, or the loop never advances.
                    _ = try? array.decode(DiscardedItem.self)
                }
            }
        }
        items = decoded
    }

    init(items: [Item], nextPageToken: String?, totalResults: Int?) {
        self.items = items
        self.nextPageToken = nextPageToken
        self.totalResults = totalResults
    }

    static var empty: YouTubePage<Item> {
        YouTubePage(items: [], nextPageToken: nil, totalResults: 0)
    }
}

/// Decodes and discards anything, so a failed element can be stepped over.
private struct DiscardedItem: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}
