import Foundation

/// Is this channel live right now, and what is it streaming?
///
/// The official answer is the YouTube Data API, which needs a key, has a daily
/// quota, and would mean shipping a credential in the app for everyone to
/// share. The unofficial answer is that `youtube.com/<channel>/live` is a real
/// page that redirects to the stream when there is one — no account, no key —
/// and the page says plainly whether what it landed on is live.
///
/// That is scraping, so this is written to fail closed. Every marker it looks
/// for has to be present and unambiguous; anything it does not understand
/// reports "not live" rather than guessing, because a card that falsely says
/// LIVE is worse than one that misses a stream by a minute.
enum YouTubeLive {

    // MARK: - URLs

    /// Accepts a `UC…` channel id or an `@handle`.
    static func channelURL(reference: String) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("@") {
            return URL(string: "https://www.youtube.com/\(trimmed)")
        }
        return URL(string: "https://www.youtube.com/channel/\(trimmed)")
    }

    static func liveURL(reference: String) -> URL? {
        guard let base = channelURL(reference: reference) else { return nil }
        return base.appendingPathComponent("live")
    }

    static func watchURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    /// Uploads and past streams, newest first. Needs a resolved `UC…` id.
    static func feedURL(channelID: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")
    }

    static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    // MARK: - Live check

    static func check(reference: String) async throws -> LiveState {
        guard let url = liveURL(reference: reference) else {
            throw FeedError.badURL(reference)
        }
        // Never a cached answer: "is it live" is the one question where a
        // ten-minute-old response is actively wrong.
        let data = try await HTTP.shared.data(
            from: url,
            accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return parse(html: XMLSanitizer.text(from: data))
    }

    /// Reads the live markers out of a watch page.
    ///
    /// Exposed rather than private so the parsing can be exercised against
    /// fixtures without a network.
    static func parse(html: String) -> LiveState {
        let now = Date()

        // `isLiveNow` is set on the currently-broadcasting player; `isLive`
        // also appears on finished streams in some payloads, so on its own it
        // is not enough. `hlsManifestUrl` is only served for an active
        // broadcast and is the strongest single marker there is.
        let hasLiveNow = html.contains("\"isLiveNow\":true")
        let hasHLS = html.contains("hlsManifestUrl")
        let hasLiveBroadcast = html.contains("\"isLiveContent\":true")
            && html.contains("\"isLive\":true")

        // A finished stream still carries live-ish metadata, and this is what
        // tells the two apart.
        let hasEnded = html.contains("\"endTimestamp\"")
            || html.contains("Streamed live")
            || html.contains("\"isLiveDvrEnabled\":false,\"isLive\":false")

        let isLive = (hasLiveNow || hasHLS || hasLiveBroadcast) && !hasEnded

        guard isLive, let videoID = videoID(in: html) else {
            return LiveState.offline(at: now)
        }

        return LiveState(
            isLive: true,
            videoID: videoID,
            title: title(in: html),
            thumbnailURL: thumbnailURL(videoID: videoID),
            checked: now
        )
    }

    /// The 11-character id of whatever the page settled on.
    static func videoID(in html: String) -> String? {
        // The canonical link is the most reliable, and it is also the marker
        // that proves the /live URL actually redirected to a watch page rather
        // than bouncing back to the channel.
        if let canonical = firstMatch(in: html,
                                      after: "<link rel=\"canonical\" href=\"https://www.youtube.com/watch?v=",
                                      until: "\""),
           isPlausibleVideoID(canonical) {
            return canonical
        }
        if let fromDetails = firstMatch(in: html, after: "\"videoId\":\"", until: "\""),
           isPlausibleVideoID(fromDetails) {
            return fromDetails
        }
        return nil
    }

    static func title(in html: String) -> String? {
        for marker in ["<meta name=\"title\" content=\"",
                       "<meta property=\"og:title\" content=\""] {
            if let raw = firstMatch(in: html, after: marker, until: "\""), !raw.isEmpty {
                return HTMLText.decodeEntities(in: raw)
            }
        }
        return nil
    }

    /// Resolves an `@handle` to the `UC…` id the RSS feed needs.
    static func resolveChannelID(reference: String) async -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("UC") && trimmed.count > 20 { return trimmed }

        guard let url = channelURL(reference: trimmed),
              let data = try? await HTTP.shared.htmlData(from: url) else { return nil }

        let html = XMLSanitizer.text(from: data)
        for marker in ["\"channelId\":\"", "<meta itemprop=\"identifier\" content=\""] {
            if let found = firstMatch(in: html, after: marker, until: "\""),
               found.hasPrefix("UC"), found.count > 20 {
                return found
            }
        }
        return nil
    }

    /// The channel's recent uploads, so an off-air card can show the last show
    /// instead of nothing.
    static func recentVideos(channelID: String, limit: Int) async -> [Article] {
        guard let url = feedURL(channelID: channelID),
              let data = try? await HTTP.shared.feedData(from: url),
              let feed = try? FeedParser.parse(data) else { return [] }

        return feed.items.prefix(limit).map {
            $0.article(sourceID: "youtube-" + channelID, siteLink: feed.siteLink)
        }
    }

    // MARK: - Small helpers

    private static func firstMatch(in html: String, after marker: String, until terminator: String) -> String? {
        guard let start = html.range(of: marker) else { return nil }
        guard let end = html[start.upperBound...].range(of: terminator) else { return nil }
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// YouTube ids are 11 characters of the URL-safe alphabet. Checking that
    /// keeps a JSON key that merely looks like one out of the player.
    static func isPlausibleVideoID(_ candidate: String) -> Bool {
        candidate.count == 11 && candidate.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}
