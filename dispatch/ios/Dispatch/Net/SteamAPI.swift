import Foundation

/// A game in the signed-in account's library.
struct SteamGame: Codable, Identifiable, Hashable {
    let appID: Int
    var name: String
    var playtimeForever: Int
    var playtimeTwoWeeks: Int

    var id: Int { appID }

    /// The store's capsule art. Wider and far more recognisable than the 32px
    /// library icon the API hands back a hash for.
    var headerURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    var storeURL: URL? {
        URL(string: "https://store.steampowered.com/app/\(appID)/")
    }

    /// How recently a game has been played, which is the order news should
    /// arrive in: patch notes for something you played this week matter, patch
    /// notes for something you bought in a 2019 sale do not.
    var recencyRank: Int {
        playtimeTwoWeeks > 0 ? 1_000_000 + playtimeTwoWeeks : playtimeForever
    }
}

struct SteamNewsItem {
    let gid: String
    let title: String
    let url: String
    let author: String
    let contents: String
    let feedLabel: String
    let date: Date?
    let isExternal: Bool
}

/// Valve's public Web API.
///
/// Two of the three calls here need no key at all — news is open — which is why
/// the app works with a manually entered game list and no credentials
/// whatsoever. The key is only ever used to *discover* a library.
actor SteamAPI {

    static let shared = SteamAPI()

    private let http: HTTP

    init(http: HTTP = .shared) {
        self.http = http
    }

    // MARK: - Library

    /// Games the account owns. Needs a Web API key and a 64-bit Steam ID.
    ///
    /// Valve returns an empty `response` object rather than an error when the
    /// profile's game details are private, so that case is detected here and
    /// given a sentence that says what to change instead of "no games".
    func ownedGames(key: String, steamID: String) async throws -> [SteamGame] {
        var components = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw FeedError.badURL(steamID) }

        let payload = try await http.json(OwnedGamesPayload.self, from: url)
        guard let games = payload.response.games else {
            throw FeedError.transport(
                "Steam returned no games. Set “Game details” to Public in your Steam privacy settings, "
                + "or add games by App ID instead."
            )
        }
        return games.map {
            SteamGame(appID: $0.appid,
                      name: $0.name ?? "App \($0.appid)",
                      playtimeForever: $0.playtime_forever ?? 0,
                      playtimeTwoWeeks: $0.playtime_2weeks ?? 0)
        }
    }

    /// Turns a `steamcommunity.com/id/<name>` vanity name into a 64-bit ID.
    func resolveVanity(key: String, vanity: String) async throws -> String {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/ResolveVanityURL/v1/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "vanityurl", value: vanity),
        ]
        guard let url = components.url else { throw FeedError.badURL(vanity) }

        let payload = try await http.json(VanityPayload.self, from: url)
        guard payload.response.success == 1, let steamID = payload.response.steamid else {
            throw FeedError.transport("No Steam account found for “\(vanity)”.")
        }
        return steamID
    }

    // MARK: - News

    /// News for one app. No key required.
    func news(appID: Int, count: Int) async throws -> [SteamNewsItem] {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: String(appID)),
            URLQueryItem(name: "count", value: String(count)),
            // 0 means "do not truncate". The reader wants the whole post, and
            // truncation here is irreversible.
            URLQueryItem(name: "maxlength", value: "0"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw FeedError.badURL(String(appID)) }

        let payload = try await http.json(NewsPayload.self, from: url)
        return (payload.appnews?.newsitems ?? []).map {
            SteamNewsItem(
                gid: $0.gid ?? UUID().uuidString,
                title: $0.title ?? "",
                url: $0.url ?? "",
                author: $0.author ?? "",
                contents: $0.contents ?? "",
                feedLabel: $0.feedlabel ?? "Steam",
                date: $0.date.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                isExternal: $0.is_external_url ?? false
            )
        }
    }

    /// Resolves a name for an App ID added by hand, so the list does not read
    /// "App 730". Best effort — the store endpoint is undocumented and rate
    /// limited, so a failure here is not an error, just a missing name.
    func storeName(appID: Int) async -> String? {
        guard let url = URL(string:
            "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic") else { return nil }
        guard let data = try? await http.data(from: url, accept: "application/json") else { return nil }

        // Keyed by the App ID as a string, so it is decoded loosely rather
        // than with a type per possible id.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any],
              entry["success"] as? Bool == true,
              let details = entry["data"] as? [String: Any],
              let name = details["name"] as? String else { return nil }
        return name
    }

    // MARK: - Payloads

    private struct OwnedGamesPayload: Decodable {
        struct Response: Decodable {
            let games: [Game]?
        }
        struct Game: Decodable {
            let appid: Int
            let name: String?
            let playtime_forever: Int?
            let playtime_2weeks: Int?
        }
        let response: Response
    }

    private struct VanityPayload: Decodable {
        struct Response: Decodable {
            let steamid: String?
            let success: Int?
        }
        let response: Response
    }

    private struct NewsPayload: Decodable {
        struct AppNews: Decodable {
            let newsitems: [Item]?
        }
        struct Item: Decodable {
            let gid: String?
            let title: String?
            let url: String?
            let author: String?
            let contents: String?
            let feedlabel: String?
            let date: Int?
            let is_external_url: Bool?
        }
        let appnews: AppNews?
    }
}

/// Steam announcement bodies are BBCode, not HTML.
///
/// The same `contents` field carries HTML when the item came from an external
/// blog, so this converts BBCode *to* HTML and lets the reader's existing HTML
/// path handle both. Doing it the other way — a second renderer for BBCode —
/// would mean two code paths for one screen.
enum SteamText {

    static func html(from contents: String) -> String {
        // An external item is already HTML; running BBCode rules over it would
        // do nothing at best and mangle a literal bracket at worst.
        if contents.contains("<p>") || contents.contains("<br") || contents.contains("<div") {
            return contents
        }

        var text = contents

        // `[url=x]label[/url]` and `[img]src[/img]` carry a payload in the tag
        // itself, so they are rewritten before the simple pairs.
        text = rewriteURLTags(in: text)
        text = rewriteSimple(in: text, tag: "img", open: "<img src=\"", close: "\">", wrapsContent: true)

        let pairs: [(String, String, String)] = [
            ("b", "<strong>", "</strong>"),
            ("i", "<em>", "</em>"),
            ("u", "<u>", "</u>"),
            ("strike", "<s>", "</s>"),
            ("h1", "<h3>", "</h3>"),
            ("h2", "<h3>", "</h3>"),
            ("h3", "<h3>", "</h3>"),
            ("list", "<ul>", "</ul>"),
            ("olist", "<ol>", "</ol>"),
            ("quote", "<blockquote>", "</blockquote>"),
            ("code", "<pre>", "</pre>"),
            ("noparse", "", ""),
            ("spoiler", "", ""),
        ]
        for (tag, open, close) in pairs {
            text = text.replacingOccurrences(of: "[\(tag)]", with: open, options: .caseInsensitive)
            text = text.replacingOccurrences(of: "[/\(tag)]", with: close, options: .caseInsensitive)
        }

        text = text.replacingOccurrences(of: "[*]", with: "<li>")
        text = text.replacingOccurrences(of: "[hr]", with: "<hr>", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "[/hr]", with: "", options: .caseInsensitive)
        // Newlines are significant in BBCode and invisible in HTML.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n", with: "<br>")
        return text
    }

    /// `[url=https://x]label[/url]` and the bare `[url]https://x[/url]`.
    private static func rewriteURLTags(in text: String) -> String {
        var out = ""
        var remainder = Substring(text)

        while let open = remainder.range(of: "[url", options: .caseInsensitive) {
            out += remainder[remainder.startIndex..<open.lowerBound]
            guard let tagEnd = remainder[open.upperBound...].firstIndex(of: "]") else {
                out += remainder[open.lowerBound...]
                return out
            }

            let attribute = remainder[open.upperBound..<tagEnd]
            let href = attribute.hasPrefix("=")
                ? String(attribute.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                : ""

            let bodyStart = remainder.index(after: tagEnd)
            guard let closeTag = remainder[bodyStart...].range(of: "[/url]", options: .caseInsensitive) else {
                out += remainder[bodyStart...]
                return out
            }

            let label = remainder[bodyStart..<closeTag.lowerBound]
            let target = href.isEmpty ? String(label) : href
            out += "<a href=\"\(target)\">\(label)</a>"
            remainder = remainder[closeTag.upperBound...]
        }
        out += remainder
        return out
    }

    private static func rewriteSimple(in text: String, tag: String,
                                      open: String, close: String,
                                      wrapsContent: Bool) -> String {
        var out = ""
        var remainder = Substring(text)

        while let start = remainder.range(of: "[\(tag)]", options: .caseInsensitive) {
            out += remainder[remainder.startIndex..<start.lowerBound]
            guard let end = remainder[start.upperBound...].range(of: "[/\(tag)]", options: .caseInsensitive) else {
                out += remainder[start.lowerBound...]
                return out
            }
            let body = remainder[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += open + (wrapsContent ? body : "") + close
            remainder = remainder[end.upperBound...]
        }
        out += remainder
        return out
    }
}

extension SteamNewsItem {

    func article(sourceID: String, game: SteamGame) -> Article {
        let body = SteamText.html(from: contents)
        let plain = HTMLText.plainText(from: body)

        return Article(
            id: sourceID + "|" + gid,
            sourceID: sourceID,
            title: HTMLText.plainText(from: title),
            summary: plain,
            bodyHTML: body,
            link: URL(string: url),
            // Steam news items carry no artwork of their own, so the game's
            // capsule stands in — which reads better in a mixed feed anyway,
            // since it identifies the game at a glance.
            imageURL: HTMLText.firstImageURL(in: body) ?? game.headerURL,
            author: author.isEmpty ? feedLabel : author,
            published: date,
            context: game.name
        )
    }
}
