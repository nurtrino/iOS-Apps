import Foundation

/// `/{board}/thread/{no}.json` — the whole thread, every post, one request.
///
/// This single endpoint is the reason this app's threading layer looks nothing
/// like a typical forum client's: there is no per-comment fetch to batch, no
/// index to fall back from, and no partially-loaded thread state to model.
struct ThreadResponse: Decodable {
    let posts: [Post]
}

/// One thread as it appears in `catalog.json`: the OP inline, plus a few
/// preview replies and the count of what was elided.
struct CatalogThread: Identifiable, Hashable, Decodable {
    let op: Post
    /// Typically the last 3–5 replies. Enough to preview, never the whole thread.
    let lastReplies: [Post]
    let omittedPosts: Int
    let omittedImages: Int
    let lastModified: Date?

    var id: Int { op.no }

    /// Total replies, preferring the OP's own count and falling back to the
    /// preview arithmetic when it is missing.
    var replyCount: Int {
        op.replyCount ?? (omittedPosts + lastReplies.count)
    }

    var imageCount: Int { op.imageCount ?? omittedImages }

    private enum CodingKeys: String, CodingKey {
        case last_replies, omitted_posts, omitted_images, last_modified
    }

    init(from decoder: Decoder) throws {
        // The OP's fields are siblings of `last_replies`, not nested, so the
        // same decoder feeds both.
        op = try Post(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastReplies = (try? c.decodeIfPresent([Post].self, forKey: .last_replies)) ?? []
        omittedPosts = c.lenientInt(.omitted_posts) ?? 0
        omittedImages = c.lenientInt(.omitted_images) ?? 0
        lastModified = c.lenientDate(.last_modified)
    }
}

/// One page of `catalog.json`. The catalog returns every page in a single
/// response, so the app holds the whole board and paginates only for render
/// cost — there is no network round trip behind scrolling.
struct CatalogPage: Decodable {
    let page: Int
    let threads: [CatalogThread]

    private enum CodingKeys: String, CodingKey {
        case page, threads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = c.lenientInt(.page) ?? 0
        threads = (try? c.decodeIfPresent([CatalogThread].self, forKey: .threads)) ?? []
    }
}

/// One thread's entry in `threads.json` — no content, just enough to know
/// whether a thread is still alive and when it last changed.
struct ThreadStub: Hashable, Decodable {
    let no: Int
    let lastModified: Date?
    let replyCount: Int

    private enum CodingKeys: String, CodingKey {
        case no, last_modified, replies
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        no = try c.decode(Int.self, forKey: .no)
        lastModified = c.lenientDate(.last_modified)
        replyCount = c.lenientInt(.replies) ?? 0
    }
}

/// One page of `threads.json`.
struct ThreadListPage: Decodable {
    let page: Int
    let threads: [ThreadStub]

    private enum CodingKeys: String, CodingKey {
        case page, threads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = c.lenientInt(.page) ?? 0
        threads = (try? c.decodeIfPresent([ThreadStub].self, forKey: .threads)) ?? []
    }
}
