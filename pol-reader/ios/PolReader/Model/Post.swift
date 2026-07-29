import Foundation

/// A staff badge attached to a post.
///
/// Unknown values decode to `.unknown` instead of throwing: the site has added
/// capcodes before, and a new one must not break parsing of the thread it
/// appears in.
enum Capcode: Hashable {
    case none
    case mod
    case admin
    case adminHighlight
    case manager
    case developer
    case founder
    case verified
    case unknown(String)

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "", "none":        self = .none
        case "mod":             self = .mod
        case "admin":           self = .admin
        case "admin_highlight": self = .adminHighlight
        case "manager":         self = .manager
        case "developer":       self = .developer
        case "founder":         self = .founder
        case "verified":        self = .verified
        default:                self = .unknown(raw ?? "")
        }
    }

    /// Text for the badge next to the poster name. `nil` for ordinary posters.
    var label: String? {
        switch self {
        case .none:            return nil
        case .mod:             return "Mod"
        case .admin:           return "Admin"
        case .adminHighlight:  return "Admin"
        case .manager:         return "Manager"
        case .developer:       return "Developer"
        case .founder:         return "Founder"
        case .verified:        return "Verified"
        case .unknown(let raw): return raw.isEmpty ? nil : raw.capitalized
        }
    }

    var isStaff: Bool { label != nil }
}

/// A file attached to a post.
///
/// The file may have been deleted after the fact, in which case the metadata
/// survives in the JSON but the bytes are gone; `isDeleted` distinguishes that
/// from a post that never had a file.
struct Attachment: Hashable {
    /// UNIX timestamp + microtime assigned at upload. This, not the original
    /// filename, is what addresses the file on the CDN.
    let tim: Int
    /// The name the file had on the poster's device, without extension.
    let originalName: String
    /// Includes the leading dot, e.g. `.jpg`.
    let ext: String
    let fileSize: Int
    let md5: String?
    let width: Int
    let height: Int
    let thumbWidth: Int
    let thumbHeight: Int
    let isSpoiler: Bool
    /// 1...5 when the board defines its own spoiler artwork.
    let customSpoiler: Int?
    let isDeleted: Bool
    let hasMobileImage: Bool

    var displayName: String { originalName + ext }

    var lowercasedExt: String { ext.lowercased() }

    /// WebM is the bulk of the video on 4chan, and the one container
    /// AVFoundation cannot decode at any OS version. It is played through
    /// WebKit instead — see `VideoSupport`.
    var isWebM: Bool { lowercasedExt == ".webm" }

    /// Containers AVFoundation decodes directly, on every supported OS version.
    var isNativelyPlayable: Bool {
        [".mp4", ".m4v", ".mov"].contains(lowercasedExt)
    }

    var isVideo: Bool { isWebM || isNativelyPlayable }

    var isAnimatedGIF: Bool { lowercasedExt == ".gif" }

    /// True for anything the in-app image viewer can actually display.
    var isDisplayableImage: Bool {
        [".jpg", ".jpeg", ".png", ".gif"].contains(lowercasedExt)
    }

    /// True for the containers the photo library accepts.
    ///
    /// The exclusion is WebM, for the same reason it cannot be played natively:
    /// Photos stores what AVFoundation understands, and that has never included
    /// it. Nothing the app does client-side changes that short of transcoding.
    var isSavableToPhotos: Bool { isDisplayableImage || isNativelyPlayable }

    var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }

    var thumbAspectRatio: Double {
        guard thumbWidth > 0, thumbHeight > 0 else { return aspectRatio }
        return Double(thumbWidth) / Double(thumbHeight)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    var dimensionsText: String { "\(width)×\(height)" }
}

/// A single post.
///
/// 4chan uses one JSON shape for the opening post of a thread and for every
/// reply — `resto == 0` marks the OP, and a handful of fields are only ever
/// populated on it. Modelling that as one type rather than an OP/reply
/// hierarchy avoids casting noise at every call site; the OP-only fields are
/// simply optional.
struct Post: Identifiable, Hashable, Decodable {

    // MARK: Identity

    /// The post number. The only field we refuse to guess at — a post without
    /// one is not addressable and is dropped.
    let no: Int
    /// The thread this post belongs to; `0` on the OP itself.
    let resto: Int

    // MARK: Timing

    let time: Date
    /// The site's own preformatted timestamp, e.g. `07/29/26(Wed)14:22:01`.
    /// Kept because it carries the board's seconds-precision when enabled.
    let nowText: String?

    // MARK: Author

    let name: String
    let trip: String?
    /// The per-thread poster ID. /pol/ has these enabled, which is what makes
    /// following one person through a thread possible at all.
    let posterID: String?
    let capcode: Capcode
    /// Four-digit year a 4chan Pass was purchased.
    let since4Pass: Int?

    // MARK: Flags
    //
    // /pol/ shows a geolocated country flag by default, but posters may instead
    // select a "board flag" — the two are mutually exclusive in practice, and
    // board flags live at a different CDN path.

    let country: String?
    let countryName: String?
    let boardFlag: String?
    let flagName: String?

    // MARK: Body

    /// OP subject line. HTML-escaped like the comment.
    let subject: String?
    /// The comment body, as the site's small HTML subset. Never render this
    /// directly — run it through `CommentParser`.
    let comment: String?

    // MARK: Attachment

    let attachment: Attachment?

    // MARK: OP-only

    let replyCount: Int?
    let imageCount: Int?
    let uniqueIPs: Int?
    let isSticky: Bool
    let isClosed: Bool
    let isArchived: Bool
    let archivedOn: Date?
    let hitBumpLimit: Bool
    let hitImageLimit: Bool
    let semanticURL: String?

    var id: Int { no }

    var isOP: Bool { resto == 0 }

    /// The thread this post lives in, whichever kind of post it is.
    var threadNo: Int { resto == 0 ? no : resto }

    /// True when the poster used the default name and no tripcode — the
    /// overwhelming majority of posts, and worth special-casing in the UI so
    /// "Anonymous" does not dominate every row.
    var isAnonymous: Bool {
        (trip?.isEmpty ?? true) && (name == "Anonymous" || name.isEmpty) && !capcode.isStaff
    }

    private enum CodingKeys: String, CodingKey {
        case no, resto, sticky, closed, now, time, name, trip, id, capcode
        case country, country_name, board_flag, flag_name
        case sub, com
        case tim, filename, ext, fsize, md5, w, h, tn_w, tn_h
        case filedeleted, spoiler, custom_spoiler, m_img
        case replies, images, bumplimit, imagelimit, semantic_url
        case since4pass, unique_ips, archived, archived_on
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        no = try c.decode(Int.self, forKey: .no)
        resto = c.lenientInt(.resto) ?? 0

        time = c.lenientDate(.time) ?? Date(timeIntervalSince1970: 0)
        nowText = c.lenientNonEmptyString(.now)

        name = c.lenientNonEmptyString(.name) ?? "Anonymous"
        trip = c.lenientNonEmptyString(.trip)
        posterID = c.lenientNonEmptyString(.id)
        capcode = Capcode(raw: c.lenientString(.capcode))
        since4Pass = c.lenientInt(.since4pass)

        country = c.lenientNonEmptyString(.country)
        countryName = c.lenientNonEmptyString(.country_name)
        boardFlag = c.lenientNonEmptyString(.board_flag)
        flagName = c.lenientNonEmptyString(.flag_name)

        subject = c.lenientNonEmptyString(.sub)
        comment = c.lenientNonEmptyString(.com)

        // The attachment is spread across a dozen sibling keys rather than
        // nested. `tim` is the one that must be present for a file to exist.
        if let tim = c.lenientInt(.tim), tim > 0, let ext = c.lenientNonEmptyString(.ext) {
            attachment = Attachment(
                tim: tim,
                originalName: c.lenientString(.filename) ?? "",
                ext: ext,
                fileSize: c.lenientInt(.fsize) ?? 0,
                md5: c.lenientNonEmptyString(.md5),
                width: c.lenientInt(.w) ?? 0,
                height: c.lenientInt(.h) ?? 0,
                thumbWidth: c.lenientInt(.tn_w) ?? 0,
                thumbHeight: c.lenientInt(.tn_h) ?? 0,
                isSpoiler: c.lenientFlag(.spoiler),
                customSpoiler: c.lenientInt(.custom_spoiler),
                isDeleted: c.lenientFlag(.filedeleted),
                hasMobileImage: c.lenientFlag(.m_img)
            )
        } else {
            attachment = nil
        }

        replyCount = c.lenientInt(.replies)
        imageCount = c.lenientInt(.images)
        uniqueIPs = c.lenientInt(.unique_ips)
        isSticky = c.lenientFlag(.sticky)
        isClosed = c.lenientFlag(.closed)
        isArchived = c.lenientFlag(.archived)
        archivedOn = c.lenientDate(.archived_on)
        hitBumpLimit = c.lenientFlag(.bumplimit)
        hitImageLimit = c.lenientFlag(.imagelimit)
        semanticURL = c.lenientNonEmptyString(.semantic_url)
    }
}
