import Foundation

/// One encoded file of a video, at a single resolution.
///
/// PeerTube exposes two URLs per file and they are not interchangeable:
/// `fileUrl` streams, `fileDownloadUrl` is the server's download route and is
/// what the site's own download button uses. Downloads use the latter so an
/// instance that meters or logs downloads sees them as downloads.
struct VideoFile: Identifiable, Hashable, Decodable {

    let id: Int
    /// Height in pixels — 1080, 720, 480… `0` marks an audio-only rendition.
    let resolution: Int
    let resolutionLabel: String
    /// Bytes. Zero when the instance declines to report it.
    let size: Int
    let fileURL: String?
    let fileDownloadURL: String?
    let fps: Double?
    let width: Int?
    let height: Int?
    let hasAudio: Bool
    let hasVideo: Bool

    /// PeerTube encodes audio-only renditions as resolution 0.
    var isAudioOnly: Bool { resolution == 0 || (!hasVideo && hasAudio) }

    var displayName: String {
        if isAudioOnly { return "Audio only" }
        if !resolutionLabel.isEmpty { return resolutionLabel }
        return "\(resolution)p"
    }

    var formattedSize: String? {
        guard size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private enum CodingKeys: String, CodingKey {
        case id, resolution, size, fileUrl, fileDownloadUrl, fps, width, height
        case hasAudio, hasVideo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id) ?? 0
        resolution = c.lenientConstantID(.resolution) ?? 0
        resolutionLabel = c.lenientConstantLabel(.resolution) ?? ""
        size = c.lenientInt(.size) ?? 0
        fileURL = c.lenientNonEmptyString(.fileUrl)
        fileDownloadURL = c.lenientNonEmptyString(.fileDownloadUrl)
        fps = c.lenientDouble(.fps)
        width = c.lenientInt(.width)
        height = c.lenientInt(.height)
        // Absent on older instances, where every file carries both.
        hasAudio = c.lenientBool(.hasAudio) ?? true
        hasVideo = c.lenientBool(.hasVideo) ?? true
    }
}

/// An HLS rendition set. `playlistUrl` is a master `.m3u8`, which AVPlayer
/// plays natively with adaptive bitrate — the preferred streaming source.
struct StreamingPlaylist: Hashable, Decodable {
    let playlistURL: String?
    let files: [VideoFile]

    private enum CodingKeys: String, CodingKey {
        case playlistUrl, files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlistURL = c.lenientNonEmptyString(.playlistUrl)
        files = (try? c.decodeIfPresent([VideoFile].self, forKey: .files)) ?? []
    }
}

/// A video as it appears in a list.
///
/// List and detail responses share most of their shape; the extra detail fields
/// live in `VideoDetails` rather than being optional here, so a screen that
/// needs a download URL cannot silently compile against a list item that has none.
struct Video: Identifiable, Hashable, Decodable {

    /// The UUID, not the numeric id. Every API route accepts it, it is stable
    /// across instances when a video is federated, and it is what the share
    /// links contain.
    let uuid: String
    let shortUUID: String?
    let numericID: Int?

    let name: String
    let truncatedDescription: String?
    /// Seconds.
    let duration: Int
    let isLive: Bool
    let nsfw: Bool

    let thumbnailPath: String?
    let previewPath: String?

    let views: Int
    let likes: Int
    let dislikes: Int
    let commentCount: Int

    let publishedAt: Date?
    let originallyPublishedAt: Date?

    let channel: ChannelSummary?
    let account: AccountSummary?

    var id: String { uuid }

    /// `HH:MM:SS`, or `M:SS` for anything under an hour.
    var formattedDuration: String {
        guard duration > 0 else { return isLive ? "LIVE" : "" }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private enum CodingKeys: String, CodingKey {
        case id, uuid, shortUUID, name, truncatedDescription, description
        case duration, isLive, nsfw, thumbnailPath, previewPath
        case views, likes, dislikes, comments
        case publishedAt, originallyPublishedAt, channel, account
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // A video without an identifier cannot be opened, played or saved, so
        // this is the one field worth failing on.
        guard let uuid = c.lenientNonEmptyString(.uuid) ?? c.lenientNonEmptyString(.shortUUID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .uuid, in: c, debugDescription: "video has no uuid"
            )
        }
        self.uuid = uuid
        shortUUID = c.lenientNonEmptyString(.shortUUID)
        numericID = c.lenientInt(.id)

        name = c.lenientNonEmptyString(.name) ?? "Untitled"
        // Older instances send the full description in list responses.
        truncatedDescription = c.lenientNonEmptyString(.truncatedDescription)
            ?? c.lenientNonEmptyString(.description)
        duration = c.lenientInt(.duration) ?? 0
        isLive = c.lenientBool(.isLive) ?? false
        nsfw = c.lenientBool(.nsfw) ?? false

        thumbnailPath = c.lenientNonEmptyString(.thumbnailPath)
        previewPath = c.lenientNonEmptyString(.previewPath)

        views = c.lenientInt(.views) ?? 0
        likes = c.lenientInt(.likes) ?? 0
        dislikes = c.lenientInt(.dislikes) ?? 0
        commentCount = c.lenientInt(.comments) ?? 0

        publishedAt = c.lenientDate(.publishedAt)
        originallyPublishedAt = c.lenientDate(.originallyPublishedAt)

        channel = try? c.decodeIfPresent(ChannelSummary.self, forKey: .channel)
        account = try? c.decodeIfPresent(AccountSummary.self, forKey: .account)
    }
}

/// A video fetched by id, carrying everything a player and a downloader need.
struct VideoDetails: Identifiable, Hashable, Decodable {

    let video: Video
    let description: String?
    let tags: [String]
    /// The uploader's own choice about whether this video may be downloaded.
    /// PeerTube exposes it per video, and the download affordance is hidden
    /// when it is false — the point of the flag is that it is respected.
    let downloadEnabled: Bool
    /// Progressive files, newest instances may leave this empty in favour of HLS.
    let files: [VideoFile]
    let streamingPlaylists: [StreamingPlaylist]
    let viewers: Int?

    var id: String { video.uuid }

    /// Every playable rendition, whichever transport the instance uses.
    var allFiles: [VideoFile] {
        (files + streamingPlaylists.flatMap(\.files))
            .sorted { $0.resolution > $1.resolution }
    }

    /// What to hand AVPlayer for streaming.
    ///
    /// HLS first: it is a single URL, adapts to the network, and AVFoundation
    /// plays it natively. Progressive MP4 is the fallback for instances that
    /// have not enabled HLS.
    var streamURL: URL? {
        if let playlist = streamingPlaylists.compactMap(\.playlistURL).first,
           let url = URL(string: playlist) {
            return url
        }
        let best = allFiles.first(where: { !$0.isAudioOnly }) ?? allFiles.first
        return best?.fileURL.flatMap(URL.init(string:))
    }

    /// Renditions offered for download, largest first. Empty when the uploader
    /// disabled downloading.
    var downloadableFiles: [VideoFile] {
        guard downloadEnabled else { return [] }
        return allFiles.filter { $0.fileDownloadURL != nil || $0.fileURL != nil }
    }

    private enum CodingKeys: String, CodingKey {
        case description, tags, downloadEnabled, files, streamingPlaylists, viewers
    }

    init(from decoder: Decoder) throws {
        video = try Video(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = c.lenientNonEmptyString(.description)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        // Absent means the instance predates the flag, when downloading was
        // always allowed.
        downloadEnabled = c.lenientBool(.downloadEnabled) ?? true
        files = (try? c.decodeIfPresent([VideoFile].self, forKey: .files)) ?? []
        streamingPlaylists =
            (try? c.decodeIfPresent([StreamingPlaylist].self, forKey: .streamingPlaylists)) ?? []
        viewers = c.lenientInt(.viewers)
    }
}
