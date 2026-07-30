package com.nurtrino.dispatch.core

/** One item in a feed, whatever produced it. */
data class Article(
    /**
     * Stable across refreshes and unique across sources, because read state keys
     * on it. Derived from the source plus the item's guid, else its link, else a
     * hash of its text — never the array index and never the date.
     */
    val id: String,
    val sourceId: String,
    val title: String,
    val summary: String = "",
    val bodyHtml: String? = null,
    /** A var because an aggregator's permalink gets rewritten to its destination. */
    var link: String? = null,
    val imageUrl: String? = null,
    val author: String? = null,
    /** Epoch milliseconds, or null when the feed carried no usable date. */
    val published: Long? = null,
    val context: String? = null,
) {
    /** A headline for sources that carry no separate title. */
    val displayTitle: String
        get() = if (title.isNotEmpty()) title else headline(summary)

    /** An item with no date sorts as old rather than pinning itself to the top. */
    val sortDate: Long get() = published ?: 0L

    /** The key two copies of the same story collide on. */
    val dedupeKey: String
        get() = link?.let { UrlCanonical.key(it) } ?: ("title:" + displayTitle.trim().lowercase())

    companion object {
        fun headline(body: String, limit: Int = 140): String {
            val trimmed = body.trim()
            if (trimmed.isEmpty()) return "Untitled"

            val newline = trimmed.indexOf('\n')
            if (newline >= 0) {
                val first = trimmed.substring(0, newline).trim()
                if (first.length >= 12) return first.take(limit)
            }
            if (trimmed.length <= limit) return trimmed

            val window = trimmed.take(limit)
            // The last sentence end inside the window, as long as it is not so
            // early that the "sentence" is really an abbreviation.
            val stop = window.indexOfLast { it in ".!?" }
            if (stop >= 20) return window.substring(0, stop + 1)
            val space = window.lastIndexOf(' ')
            return if (space > 0) window.substring(0, space) + "…" else "$window…"
        }
    }
}

/**
 * A hash that means the same thing on every launch.
 *
 * Kotlin's `String.hashCode` is stable, unlike Swift's, but this stays FNV-1a so
 * an article id computed on Android matches the one computed on iOS — the two
 * apps read the same feeds and there is no reason for their ids to disagree.
 */
object StableHash {
    fun hex(text: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= 0x100000001B3L
        }
        return java.lang.Long.toHexString(hash)
    }
}

/** Reduces a URL to the part that identifies the page. */
object UrlCanonical {

    private val NOISE = setOf(
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_name", "fbclid", "gclid", "msclkid", "igshid", "mc_cid",
        "mc_eid", "ref", "referrer", "source", "amp", "__twitter_impression",
    )

    fun key(url: String): String? {
        val withoutScheme = url.substringAfter("//", "")
        if (withoutScheme.isEmpty()) return null

        val withoutFragment = withoutScheme.substringBefore('#')
        var host = withoutFragment.substringBefore('/').substringBefore('?').lowercase()
        if (host.isEmpty()) return null
        if (host.startsWith("www.")) host = host.substring(4)

        val afterHost = withoutFragment.removePrefix(withoutFragment.substringBefore('/'))
        var path = afterHost.substringBefore('?')
        while (path.length > 1 && path.endsWith('/')) path = path.dropLast(1)

        val query = afterHost.substringAfter('?', "")
        val kept = query.split('&')
            .filter { it.isNotEmpty() && !NOISE.contains(it.substringBefore('=').lowercase()) }
            .sorted()

        return host + path + if (kept.isEmpty()) "" else "?" + kept.joinToString("&")
    }
}
