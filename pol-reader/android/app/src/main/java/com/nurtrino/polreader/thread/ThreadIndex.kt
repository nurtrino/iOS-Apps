package com.nurtrino.polreader.thread

import com.nurtrino.polreader.model.Post
import com.nurtrino.polreader.text.CommentMarkup

/** A post's position in the derived reply tree. */
data class ThreadNode(val postNo: Int, val depth: Int) {
    /** Indentation is capped, or a long back-and-forth squeezes text to nothing. */
    val indentDepth: Int get() = minOf(depth, MAX_INDENT_DEPTH)

    companion object {
        const val MAX_INDENT_DEPTH = 8
    }
}

/**
 * Everything derived from one thread's posts.
 *
 * 4chan threads are **flat**: the JSON is a plain array in posting order, and
 * replies are expressed only as `>>123` quotelinks inside the comment HTML.
 * That inverts the usual forum-client problem. There is no tree to flatten on
 * arrival — instead the two things worth precomputing are the **backlink
 * index**, which the API does not provide at all, and an optional **derived
 * tree** for threaded reading. Both are one linear pass.
 *
 * Mirrors `ios/PolReader/Thread/ThreadIndex.swift`; the algorithms are asserted
 * in `tools/test_thread.py`.
 */
class ThreadIndex(val board: String, val posts: List<Post>) {

    private val offsets: Map<Int, Int> = posts.withIndex().associate { (i, p) -> p.no to i }

    /** Post number to the posts it quotes, in body order. */
    val quotes: Map<Int, List<Int>>

    /** Post number to the posts that quote it, in posting order. */
    val backlinks: Map<Int, List<Int>>

    init {
        val quotesBuilder = mutableMapOf<Int, List<Int>>()
        val backlinksBuilder = mutableMapOf<Int, MutableList<Int>>()

        for (post in posts) {
            val quoted = CommentMarkup.quotedPostNumbers(post.comment)
            if (quoted.isEmpty()) continue
            quotesBuilder[post.no] = quoted
            for (target in quoted) {
                // A quote pointing outside this thread means the target was
                // deleted. Nothing to hang a backlink on; the UI renders it as
                // a dead link.
                if (!offsets.containsKey(target)) continue
                backlinksBuilder.getOrPut(target) { mutableListOf() }.add(post.no)
            }
        }
        quotes = quotesBuilder
        backlinks = backlinksBuilder
    }

    val op: Post? get() = posts.firstOrNull { it.isOp } ?: posts.firstOrNull()

    fun post(no: Int): Post? = offsets[no]?.let { posts[it] }

    fun contains(no: Int): Boolean = offsets.containsKey(no)

    fun repliesTo(no: Int): List<Int> = backlinks[no].orEmpty()

    /**
     * Every post by the given per-thread poster ID. /pol/ has poster IDs
     * enabled, which makes following one person through a thread possible.
     */
    fun postsByPosterId(posterId: String): List<Int> =
        posts.filter { it.posterId == posterId }.map { it.no }

    val distinctPosterIds: Set<String> get() = posts.mapNotNull { it.posterId }.toSet()

    /**
     * The thread as a depth-tagged array in reading order.
     *
     * A post's parent is the first post it quotes that appears **earlier** in
     * the thread. Requiring "earlier" is what makes cycles impossible: 4chan
     * does not stop two posters from quoting each other, and a naive
     * "first quotelink is the parent" rule builds an infinite loop out of that.
     */
    fun threadedOutline(): List<ThreadNode> {
        val root = op ?: return emptyList()

        val children = mutableMapOf<Int, MutableList<Int>>()
        for ((index, post) in posts.withIndex()) {
            if (post.no == root.no) continue
            var parent = root.no
            for (candidate in quotes[post.no].orEmpty()) {
                val candidateOffset = offsets[candidate]
                if (candidateOffset != null && candidateOffset < index) {
                    parent = candidate
                    break
                }
            }
            children.getOrPut(parent) { mutableListOf() }.add(post.no)
        }

        val outline = ArrayList<ThreadNode>(posts.size)
        // Explicit stack rather than recursion: threads run to hundreds of
        // posts and a pathological quote chain would be deep enough to matter.
        val stack = ArrayDeque<Pair<Int, Int>>()
        stack.addLast(root.no to 0)
        val visited = mutableSetOf<Int>()

        while (stack.isNotEmpty()) {
            val (no, depth) = stack.removeLast()
            if (!visited.add(no)) continue
            outline.add(ThreadNode(no, depth))
            // Pushed reversed so the first child pops first, keeping the output
            // in posting order.
            children[no]?.asReversed()?.forEach { stack.addLast(it to depth + 1) }
        }

        // Any post unreachable from the OP is appended rather than lost.
        for (post in posts) {
            if (post.no !in visited) outline.add(ThreadNode(post.no, 1))
        }
        return outline
    }

    /** The thread as it arrives: flat, chronological, every post at depth zero. */
    fun flatOutline(): List<ThreadNode> = posts.map { ThreadNode(it.no, 0) }
}

/**
 * Pure functions over a depth-tagged array. Free of the index, so they work for
 * any outline and can be tested without building a thread at all.
 */
object Outline {

    /** Descendants under each node, positionally aligned with [nodes]. */
    fun descendantCounts(nodes: List<ThreadNode>): IntArray {
        val counts = IntArray(nodes.size)
        val ancestors = mutableListOf<Int>()
        for (i in nodes.indices) {
            while (ancestors.isNotEmpty() && nodes[ancestors.last()].depth >= nodes[i].depth) {
                ancestors.removeAt(ancestors.size - 1)
            }
            for (ancestor in ancestors) counts[ancestor]++
            ancestors.add(i)
        }
        return counts
    }

    /**
     * Drop the subtrees under every collapsed node.
     *
     * Collapsing is a linear skip over the following run of deeper nodes — no
     * tree mutation, and the result is still a flat list, which is what the
     * recycling list wants anyway.
     */
    fun visible(nodes: List<ThreadNode>, collapsed: Set<Int>): List<ThreadNode> {
        if (collapsed.isEmpty()) return nodes
        val out = ArrayList<ThreadNode>(nodes.size)
        var i = 0
        while (i < nodes.size) {
            val node = nodes[i]
            out.add(node)
            i++
            if (node.postNo in collapsed) {
                while (i < nodes.size && nodes[i].depth > node.depth) i++
            }
        }
        return out
    }

    /**
     * Remove nodes failing [keep], along with everything beneath them.
     *
     * Hiding a post has to hide the replies hanging off it too, or the thread
     * is left with orphans quoting something the reader cannot see.
     */
    fun filtered(nodes: List<ThreadNode>, keep: (Int) -> Boolean): List<ThreadNode> {
        val out = ArrayList<ThreadNode>(nodes.size)
        var i = 0
        while (i < nodes.size) {
            val node = nodes[i]
            if (keep(node.postNo)) {
                out.add(node)
                i++
            } else {
                i++
                while (i < nodes.size && nodes[i].depth > node.depth) i++
            }
        }
        return out
    }
}
