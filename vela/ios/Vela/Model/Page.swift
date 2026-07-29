import Foundation

/// PeerTube's list envelope: `{ total, data }`.
///
/// `total` is what makes "load more" honest — the client knows when it has
/// everything rather than paging until a short response happens to arrive.
struct Page<Item: Decodable>: Decodable {
    let total: Int
    let items: [Item]

    init(total: Int, items: [Item]) {
        self.total = total
        self.items = items
    }

    /// For requests that are answered without asking the server — an empty
    /// search box, say.
    static var empty: Page<Item> { Page(total: 0, items: []) }

    private enum CodingKeys: String, CodingKey {
        case total, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.lenientInt(.total) ?? 0
        // A single malformed entry must not empty the whole page, so items are
        // decoded individually and the bad ones dropped.
        var unkeyed = try? c.nestedUnkeyedContainer(forKey: .data)
        var collected: [Item] = []
        while let container = unkeyed, !container.isAtEnd {
            var mutable = container
            if let item = try? mutable.decode(Item.self) {
                collected.append(item)
            } else {
                // Skip the entry that failed, or the loop cannot advance.
                _ = try? mutable.decode(DiscardedValue.self)
            }
            unkeyed = mutable
        }
        items = collected
    }
}

/// Consumes exactly one value of any shape, so a failed element can be stepped
/// over without knowing what it was.
private struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

/// Where a screen is in its load cycle.
///
/// Deliberately not generic over the value: stores hold their data separately,
/// so a failed refresh can leave existing content on screen while still
/// surfacing the error. Bundling them forces a choice between showing stale
/// content and showing the error, and usually both are wanted.
enum LoadPhase: Equatable {
    case idle
    case loading
    case refreshing
    case loadingMore
    case loaded
    case failed(String)

    var isBusy: Bool {
        self == .loading || self == .refreshing || self == .loadingMore
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// How a video list is ordered. PeerTube takes these verbatim as `sort`.
enum VideoSort: String, CaseIterable, Identifiable {
    case trending = "-trending"
    case recent = "-publishedAt"
    case views = "-views"
    case likes = "-likes"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .recent: return "Recent"
        case .views: return "Most viewed"
        case .likes: return "Most liked"
        }
    }
}
