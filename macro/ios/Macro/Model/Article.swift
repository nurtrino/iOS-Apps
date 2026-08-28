import Foundation

/// One story, from whichever feed it came from.
struct Article: Identifiable, Hashable, Codable {
    let id: String
    let sourceID: String
    let title: String
    /// Plain text, already stripped of markup, for the two-line dek.
    let summary: String
    let link: URL?
    let imageURL: URL?
    let published: Date?

    /// What merged sorting uses. An item with no parseable date sorts to the
    /// bottom rather than pretending it just happened.
    var sortDate: Date { published ?? .distantPast }

    var sourceName: String {
        FeedCatalog.source(withID: sourceID)?.name ?? sourceID
    }

    /// The identity that has to survive a re-fetch.
    ///
    /// Preference order is deliberate: a `guid` is the publisher's own promise
    /// of stability, a link is nearly as good, and hashing the text is the last
    /// resort for feeds that offer neither. Falling through to the array index
    /// would be easier and would mark the whole feed unread on every refresh.
    static func stableID(sourceID: String, guid: String?, link: String?, fallback: String) -> String {
        if let guid, !guid.isEmpty { return sourceID + "|" + guid }
        if let link, !link.isEmpty { return sourceID + "|" + link }
        return sourceID + "|#" + StableHash.hex(String(fallback.prefix(220)))
    }
}

/// FNV-1a, because the id has to be identical across launches and devices —
/// `Hasher` is seeded per process and would mark everything unread on every
/// launch.
enum StableHash {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
