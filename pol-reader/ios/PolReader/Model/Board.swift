import Foundation

/// A board's metadata, as served by `boards.json`.
///
/// The app is built around /pol/, but boards are still modelled properly rather
/// than hard-coded: cross-board quotelinks (`>>>/b/`) and the archive both need
/// to name a board that is not the current one, and the per-board flag
/// dictionary is what turns a `board_flag` code into a readable name.
struct Board: Identifiable, Hashable, Decodable {

    /// The short code without slashes, e.g. `pol`.
    let board: String
    let title: String
    /// False for boards that are not worksafe. /pol/ is one of them, which is
    /// why image blurring defaults on.
    let isWorkSafe: Bool
    let pages: Int
    let threadsPerPage: Int
    let bumpLimit: Int
    let imageLimit: Int
    let maxCommentChars: Int
    let maxFileSize: Int
    let maxWebMFileSize: Int
    let description: String?
    /// Number of custom spoiler images the board defines, `0` for none.
    let customSpoilers: Int
    let hasCountryFlags: Bool
    /// Per-thread poster IDs. Enabled on /pol/.
    let hasUserIDs: Bool
    let hasCodeTags: Bool
    let isArchived: Bool
    let isTextOnly: Bool
    let forcedAnon: Bool
    /// Board flag code to display name, e.g. `"DE": "Nazi Germany"` on /pol/.
    /// Used to label a flag without a second request.
    let boardFlags: [String: String]

    var id: String { board }

    /// `/pol/`
    var slashName: String { "/\(board)/" }

    private enum CodingKeys: String, CodingKey {
        case board, title, ws_board, pages, per_page, bump_limit, image_limit
        case max_comment_chars, max_filesize, max_webm_filesize
        case meta_description, custom_spoilers, country_flags, user_ids
        case code_tags, is_archived, text_only, forced_anon, board_flags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try c.decode(String.self, forKey: .board)
        title = c.lenientNonEmptyString(.title) ?? board
        isWorkSafe = c.lenientFlag(.ws_board)
        pages = c.lenientInt(.pages) ?? 10
        threadsPerPage = c.lenientInt(.per_page) ?? 15
        bumpLimit = c.lenientInt(.bump_limit) ?? 300
        imageLimit = c.lenientInt(.image_limit) ?? 150
        maxCommentChars = c.lenientInt(.max_comment_chars) ?? 2000
        maxFileSize = c.lenientInt(.max_filesize) ?? 4_194_304
        maxWebMFileSize = c.lenientInt(.max_webm_filesize) ?? 3_145_728
        description = c.lenientNonEmptyString(.meta_description)
        customSpoilers = c.lenientInt(.custom_spoilers) ?? 0
        hasCountryFlags = c.lenientFlag(.country_flags)
        hasUserIDs = c.lenientFlag(.user_ids)
        hasCodeTags = c.lenientFlag(.code_tags)
        isArchived = c.lenientFlag(.is_archived)
        isTextOnly = c.lenientFlag(.text_only)
        forcedAnon = c.lenientFlag(.forced_anon)
        boardFlags = (try? c.decodeIfPresent([String: String].self, forKey: .board_flags)) ?? [:]
    }

    private init(
        board: String, title: String, isWorkSafe: Bool, pages: Int, threadsPerPage: Int,
        bumpLimit: Int, imageLimit: Int, maxCommentChars: Int, maxFileSize: Int,
        maxWebMFileSize: Int, description: String?, customSpoilers: Int,
        hasCountryFlags: Bool, hasUserIDs: Bool, hasCodeTags: Bool, isArchived: Bool,
        isTextOnly: Bool, forcedAnon: Bool, boardFlags: [String: String]
    ) {
        self.board = board
        self.title = title
        self.isWorkSafe = isWorkSafe
        self.pages = pages
        self.threadsPerPage = threadsPerPage
        self.bumpLimit = bumpLimit
        self.imageLimit = imageLimit
        self.maxCommentChars = maxCommentChars
        self.maxFileSize = maxFileSize
        self.maxWebMFileSize = maxWebMFileSize
        self.description = description
        self.customSpoilers = customSpoilers
        self.hasCountryFlags = hasCountryFlags
        self.hasUserIDs = hasUserIDs
        self.hasCodeTags = hasCodeTags
        self.isArchived = isArchived
        self.isTextOnly = isTextOnly
        self.forcedAnon = forcedAnon
        self.boardFlags = boardFlags
    }

    /// A built-in description of /pol/ so the first launch can render a catalog
    /// without waiting on `boards.json`. Refreshed from the network when that
    /// request lands.
    static let pol = Board(
        board: "pol",
        title: "Politically Incorrect",
        isWorkSafe: false,
        pages: 10,
        threadsPerPage: 15,
        bumpLimit: 300,
        imageLimit: 300,
        maxCommentChars: 2000,
        maxFileSize: 4_194_304,
        maxWebMFileSize: 3_145_728,
        description: nil,
        customSpoilers: 0,
        hasCountryFlags: true,
        hasUserIDs: true,
        hasCodeTags: false,
        isArchived: true,
        isTextOnly: false,
        forcedAnon: true,
        boardFlags: [:]
    )
}

/// Envelope for `boards.json`.
struct BoardsResponse: Decodable {
    let boards: [Board]
}
