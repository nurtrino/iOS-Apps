import Foundation

/// A post's position in the derived reply tree.
struct ThreadNode: Hashable, Identifiable {
    let postNo: Int
    let depth: Int

    var id: Int { postNo }

    /// Indentation is capped well below the real depth, or a long back-and-forth
    /// squeezes the text down to nothing on a phone.
    static let maxIndentDepth = 8

    var indentDepth: Int { min(depth, ThreadNode.maxIndentDepth) }
}

/// Everything derived from one thread's posts.
///
/// 4chan threads are **flat**: the JSON is a plain array in posting order, and
/// replies are expressed only as `>>123` quotelinks inside the comment HTML.
/// That inverts the usual forum-client problem. There is no tree to flatten on
/// arrival — instead the two things worth precomputing are:
///
/// 1. the **backlink index**, which the API does not provide at all and which
///    is what makes "3 replies" badges and reply navigation possible; and
/// 2. an optional **derived tree**, for readers who prefer threaded reading to
///    the chronological default.
///
/// Both are one linear pass over the posts.
struct ThreadIndex {

    let board: String
    /// Posts in the site's own order, which is chronological.
    let posts: [Post]

    /// Post number to its offset in `posts`.
    private let offsets: [Int: Int]
    /// Post number to the posts it quotes, in the order they appear in its body.
    let quotes: [Int: [Int]]
    /// Post number to the posts that quote it, in posting order.
    let backlinks: [Int: [Int]]

    /// Post number to the post it replies to. Derived once here rather than
    /// inside the outline, so the threaded view can ask "who is this answering?"
    /// without rebuilding the tree. The OP has no entry.
    let parents: [Int: Int]

    init(board: String, posts: [Post]) {
        self.board = board
        self.posts = posts

        var offsets: [Int: Int] = [:]
        offsets.reserveCapacity(posts.count)
        for (index, post) in posts.enumerated() {
            offsets[post.no] = index
        }
        self.offsets = offsets

        var quotes: [Int: [Int]] = [:]
        var backlinks: [Int: [Int]] = [:]
        quotes.reserveCapacity(posts.count)

        for post in posts {
            let quoted = CommentMarkup.quotedPostNumbers(in: post.comment)
            guard !quoted.isEmpty else { continue }
            quotes[post.no] = quoted
            for target in quoted {
                // A quote pointing outside this thread means the target was
                // deleted, or the quote was a typo. Either way there is nothing
                // to hang a backlink on; the UI renders it as a dead link.
                guard offsets[target] != nil else { continue }
                backlinks[target, default: []].append(post.no)
            }
        }
        self.quotes = quotes
        self.backlinks = backlinks

        // A post's parent is the first post it quotes that appears *earlier* in
        // the thread. Requiring "earlier" is what makes cycles impossible: 4chan
        // does not stop two posters from quoting each other, and a naive
        // "first quotelink is the parent" rule builds an infinite loop from it.
        var parents: [Int: Int] = [:]
        if let root = posts.first(where: { $0.isOP }) ?? posts.first {
            parents.reserveCapacity(posts.count)
            for (index, post) in posts.enumerated() where post.no != root.no {
                var parent = root.no
                for candidate in quotes[post.no] ?? [] {
                    if let candidateOffset = offsets[candidate], candidateOffset < index {
                        parent = candidate
                        break
                    }
                }
                parents[post.no] = parent
            }
        }
        self.parents = parents
    }

    // MARK: - Lookup

    var op: Post? {
        posts.first(where: { $0.isOP }) ?? posts.first
    }

    var opNo: Int { op?.no ?? 0 }

    func post(_ no: Int) -> Post? {
        guard let offset = offsets[no] else { return nil }
        return posts[offset]
    }

    func contains(_ no: Int) -> Bool { offsets[no] != nil }

    /// Posts that quoted this one.
    func replies(to no: Int) -> [Int] { backlinks[no] ?? [] }

    /// Posts this one quoted and that are still present in the thread.
    func quoted(by no: Int) -> [Int] {
        (quotes[no] ?? []).filter { offsets[$0] != nil }
    }

    /// Every post by the given per-thread poster ID. /pol/ has poster IDs
    /// enabled, which makes following one person through a thread possible.
    func posts(byPosterID posterID: String) -> [Int] {
        posts.filter { $0.posterID == posterID }.map(\.no)
    }

    /// Distinct poster IDs seen in the thread, for the "N posters" readout when
    /// `unique_ips` is absent.
    var distinctPosterIDs: Set<String> {
        Set(posts.compactMap(\.posterID))
    }

    // MARK: - Derived tree

    /// The thread as a depth-tagged array in reading order.
    ///
    /// A post's parent is the first post it quotes that appears **earlier** in
    /// the thread. Requiring the parent to be strictly earlier is what makes
    /// cycles impossible: 4chan does not stop anyone from quoting a post that
    /// quotes them back, and a naive "first quotelink is the parent" rule
    /// happily builds an infinite loop out of that.
    ///
    /// Posts that quote nothing, or quote only deleted or later posts, hang off
    /// the OP.
    func threadedOutline() -> [ThreadNode] {
        guard let op else { return [] }

        var children: [Int: [Int]] = [:]
        for post in posts where post.no != op.no {
            guard let parent = parents[post.no] else { continue }
            children[parent, default: []].append(post.no)
        }

        var outline: [ThreadNode] = []
        outline.reserveCapacity(posts.count)

        // Explicit stack rather than recursion: threads run to hundreds of
        // posts and a pathological quote chain would otherwise be deep enough
        // to matter.
        var stack: [(no: Int, depth: Int)] = [(op.no, 0)]
        var visited = Set<Int>()
        while let current = stack.popLast() {
            guard visited.insert(current.no).inserted else { continue }
            outline.append(ThreadNode(postNo: current.no, depth: current.depth))
            if let kids = children[current.no] {
                // Pushed reversed so the first child is popped first, which
                // keeps the output in posting order.
                for child in kids.reversed() {
                    stack.append((child, current.depth + 1))
                }
            }
        }

        // Any post unreachable from the OP (possible only if the OP itself
        // quotes forward into a cycle we broke) is appended rather than lost.
        for post in posts where !visited.contains(post.no) {
            outline.append(ThreadNode(postNo: post.no, depth: 1))
        }

        return outline
    }

    /// The thread as it arrives: flat, chronological, every post at depth zero.
    func flatOutline() -> [ThreadNode] {
        posts.map { ThreadNode(postNo: $0.no, depth: 0) }
    }

    /// Every post above this one in the derived tree, nearest first.
    ///
    /// The `seen` set is belt-and-braces: `parents` is already acyclic by
    /// construction, but an ancestor walk that can loop is the kind of thing
    /// that hangs the UI rather than failing loudly.
    func ancestors(of postNo: Int) -> [Int] {
        var result: [Int] = []
        var seen: Set<Int> = []
        var current = parents[postNo]
        while let node = current, seen.insert(node).inserted {
            result.append(node)
            current = parents[node]
        }
        return result
    }
}

// MARK: - Outline operations
//
// These are pure functions over a depth-tagged array. Keeping them free of the
// index means they work for any outline, and can be tested without building a
// thread at all.

enum Outline {

    /// Number of descendants under each node, positionally aligned with
    /// `nodes`. One pass with a stack of open ancestors.
    static func descendantCounts(_ nodes: [ThreadNode]) -> [Int] {
        var counts = [Int](repeating: 0, count: nodes.count)
        var ancestors: [Int] = []  // indices into `nodes`
        for i in nodes.indices {
            while let last = ancestors.last, nodes[last].depth >= nodes[i].depth {
                ancestors.removeLast()
            }
            for ancestor in ancestors {
                counts[ancestor] += 1
            }
            ancestors.append(i)
        }
        return counts
    }

    /// Drop the subtrees under every collapsed node.
    ///
    /// Collapsing is a linear skip over the following run of deeper nodes — no
    /// tree mutation, and the result is still a flat array, which is what the
    /// recycling list wants anyway.
    static func visible(_ nodes: [ThreadNode], collapsed: Set<Int>) -> [ThreadNode] {
        guard !collapsed.isEmpty else { return nodes }
        var out: [ThreadNode] = []
        out.reserveCapacity(nodes.count)
        var i = 0
        while i < nodes.count {
            let node = nodes[i]
            out.append(node)
            i += 1
            if collapsed.contains(node.postNo) {
                while i < nodes.count, nodes[i].depth > node.depth {
                    i += 1
                }
            }
        }
        return out
    }

    /// Remove nodes whose post fails `predicate`, along with everything beneath
    /// them.
    ///
    /// Used by the filter list: hiding a post has to hide the replies that hang
    /// off it too, or the thread is left with orphans quoting something the
    /// reader cannot see.
    static func filtered(_ nodes: [ThreadNode], keep predicate: (Int) -> Bool) -> [ThreadNode] {
        var out: [ThreadNode] = []
        out.reserveCapacity(nodes.count)
        var i = 0
        while i < nodes.count {
            let node = nodes[i]
            if predicate(node.postNo) {
                out.append(node)
                i += 1
            } else {
                i += 1
                while i < nodes.count, nodes[i].depth > node.depth {
                    i += 1
                }
            }
        }
        return out
    }
}
