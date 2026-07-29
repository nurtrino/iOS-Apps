import Foundation

/// URL construction for everything that is not the JSON API.
///
/// 4chan splits its content across three hosts, and the paths are the part of
/// the API most easily got subtly wrong — board flags in particular do *not*
/// live under the country-flag path.
enum MediaURL {

    private static let media = "https://i.4cdn.org"
    private static let staticContent = "https://s.4cdn.org"
    private static let boards = "https://boards.4chan.org"

    /// The full-size upload: `https://i.4cdn.org/pol/1690000000000.jpg`
    ///
    /// Addressed by `tim`, the upload timestamp — never by the original
    /// filename, which is display-only and frequently not unique.
    static func file(board: String, attachment: Attachment) -> URL? {
        URL(string: "\(media)/\(board)/\(attachment.tim)\(attachment.ext)")
    }

    /// The thumbnail: `https://i.4cdn.org/pol/1690000000000s.jpg`
    ///
    /// Always `.jpg` regardless of the source file's type.
    static func thumbnail(board: String, attachment: Attachment) -> URL? {
        URL(string: "\(media)/\(board)/\(attachment.tim)s.jpg")
    }

    /// A geolocated country flag: `https://s.4cdn.org/image/country/us.gif`
    static func countryFlag(_ code: String) -> URL? {
        let cleaned = code.lowercased().trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "\(staticContent)/image/country/\(cleaned).gif")
    }

    /// A board flag — on /pol/, the user-selectable flags shown instead of a
    /// country: `https://s.4cdn.org/image/flags/pol/tx.gif`
    ///
    /// Note the path is `/image/flags/<board>/`, not the country path. Getting
    /// this wrong yields a silent 404 on every flagged post.
    static func boardFlag(board: String, code: String) -> URL? {
        let cleaned = code.lowercased().trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "\(staticContent)/image/flags/\(board)/\(cleaned).gif")
    }

    /// The spoiler placeholder shown in place of a spoilered thumbnail.
    /// Boards may define their own numbered variants; /pol/ does not.
    static func spoiler(board: String, customSpoiler: Int?) -> URL? {
        if let customSpoiler, customSpoiler > 0 {
            return URL(string: "\(staticContent)/image/spoiler-\(board)\(customSpoiler).png")
        }
        return URL(string: "\(staticContent)/image/spoiler.png")
    }

    /// The thread on the website, for the "open in browser" affordance. The app
    /// is read-only, so anything requiring an account leaves for the site.
    static func webThread(board: String, threadNo: Int, postNo: Int? = nil) -> URL? {
        var string = "\(boards)/\(board)/thread/\(threadNo)"
        if let postNo, postNo != threadNo {
            string += "#p\(postNo)"
        }
        return URL(string: string)
    }

    static func webBoard(_ board: String) -> URL? {
        URL(string: "\(boards)/\(board)/")
    }
}
