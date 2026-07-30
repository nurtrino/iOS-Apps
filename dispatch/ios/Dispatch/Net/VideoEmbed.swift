import Foundation

/// A video an article is really about, and where to play it.
///
/// A link aggregator's post is often a video with a sentence under it. Opening
/// that as a web page means a cookie banner, a consent dialog and then a player,
/// when the content is thirty seconds of footage. This finds the video and the
/// reader plays it in place.
struct VideoEmbed: Equatable, Hashable {

    enum Host: Equatable, Hashable {
        case youtube(id: String)
        /// Anything else that supplies a direct file — Telegram's CDN, mostly.
        case file(URL)
    }

    let host: Host

    /// The page to fall back to when embedding is refused.
    let watchURL: URL?

    var youtubeID: String? {
        if case .youtube(let id) = host { return id }
        return nil
    }

    var fileURL: URL? {
        if case .file(let url) = host { return url }
        return nil
    }
}

enum VideoEmbedFinder {

    /// The video in an article, if it has one.
    ///
    /// Order matters. A direct file the feed handed us is better than anything
    /// scraped, then the article's own link, then whatever the body embeds — a
    /// body can contain a related-video sidebar, and the link is more likely to
    /// be the thing the post is about.
    static func find(link: URL?, bodyHTML: String?, fileURL: URL?) -> VideoEmbed? {
        if let fileURL {
            return VideoEmbed(host: .file(fileURL), watchURL: link)
        }
        if let link, let id = youtubeID(in: link.absoluteString) {
            return VideoEmbed(host: .youtube(id: id), watchURL: link)
        }
        if let bodyHTML, let id = firstYouTubeID(inHTML: bodyHTML) {
            return VideoEmbed(host: .youtube(id: id),
                              watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)"))
        }
        return nil
    }

    /// A YouTube id out of any of the shapes a link takes.
    ///
    /// All five appear in feeds: `watch?v=`, the `youtu.be` short form, `/embed/`
    /// from an iframe, `/live/` from a stream, and `/shorts/`. Matching only the
    /// first is why an embedded player looks broken on half the posts that have
    /// one.
    static func youtubeID(in text: String) -> String? {
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased() else { return nil }

        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path

        if bare == "youtu.be" {
            return valid(String(path.dropFirst()))
        }
        guard bare == "youtube.com" || bare == "m.youtube.com" || bare == "youtube-nocookie.com" else {
            return nil
        }
        if path == "/watch" {
            return valid(components.queryItems?.first { $0.name == "v" }?.value ?? "")
        }
        for prefix in ["/embed/", "/live/", "/shorts/", "/v/"] where path.hasPrefix(prefix) {
            return valid(String(path.dropFirst(prefix.count)))
        }
        return nil
    }

    /// The first YouTube link in a body, iframe or anchor.
    static func firstYouTubeID(inHTML html: String) -> String? {
        for attribute in ["src", "href", "data-src"] {
            let pattern = "\(attribute)\\s*=\\s*[\"']([^\"']*)[\"']"
            guard let expression = try? NSRegularExpression(pattern: pattern,
                                                            options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in expression.matches(in: html, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: html) else { continue }
                let value = String(html[valueRange])
                if let id = youtubeID(in: value) { return id }
            }
        }
        return nil
    }

    /// An id is eleven URL-safe characters. Checking stops a truncated or
    /// tracking-laden path becoming a player that loads nothing.
    private static func valid(_ candidate: String) -> String? {
        let id = candidate.split(separator: "?").first.map(String.init) ?? candidate
        guard id.count == 11 else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id
    }
}
