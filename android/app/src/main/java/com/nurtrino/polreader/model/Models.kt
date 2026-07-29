package com.nurtrino.polreader.model

import org.json.JSONArray
import org.json.JSONObject

/**
 * 4chan's JSON omits keys entirely for absent values, sends integers where
 * booleans are meant (`0`/`1`), and occasionally sends a string where the
 * documentation promises a number. Decoding must survive all of that: one bad
 * post in a 400-post thread should not blank the whole screen.
 *
 * Every field except the post number is read through these helpers. `org.json`
 * rather than a serialization library precisely because it is this lenient by
 * nature — a strict schema is the wrong tool for a lenient source.
 */
private fun JSONObject.str(key: String): String? {
    if (!has(key) || isNull(key)) return null
    val value = optString(key, "")
    return value.ifEmpty { null }
}

private fun JSONObject.nonBlank(key: String): String? = str(key)?.trim()?.ifEmpty { null }

private fun JSONObject.int(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    if (opt(key) is Number) return optInt(key)
    return optString(key, "").toIntOrNull()
}

/** 4chan encodes booleans as 0/1, and usually omits the key rather than sending 0. */
private fun JSONObject.flag(key: String): Boolean = (int(key) ?: 0) != 0

/** A UNIX timestamp in seconds; 0 means "never". */
private fun JSONObject.epoch(key: String): Long? = int(key)?.toLong()?.takeIf { it > 0 }

/**
 * A staff badge. Unknown values become [Unknown] rather than throwing: the site
 * has added capcodes before, and a new one must not break parsing.
 */
sealed interface Capcode {
    object None : Capcode
    object Mod : Capcode
    object Admin : Capcode
    object Manager : Capcode
    object Developer : Capcode
    object Founder : Capcode
    object Verified : Capcode
    data class Unknown(val raw: String) : Capcode

    val label: String?
        get() = when (this) {
            None -> null
            Mod -> "Mod"
            Admin -> "Admin"
            Manager -> "Manager"
            Developer -> "Developer"
            Founder -> "Founder"
            Verified -> "Verified"
            is Unknown -> raw.ifEmpty { null }
        }

    companion object {
        fun from(raw: String?): Capcode = when (raw?.lowercase() ?: "") {
            "", "none" -> None
            "mod" -> Mod
            "admin", "admin_highlight" -> Admin
            "manager" -> Manager
            "developer" -> Developer
            "founder" -> Founder
            "verified" -> Verified
            else -> Unknown(raw ?: "")
        }
    }
}

/**
 * A file attached to a post. The file may have been deleted after the fact, in
 * which case the metadata survives but the bytes are gone.
 */
data class Attachment(
    /** Upload timestamp; this, not the original filename, addresses the file on the CDN. */
    val tim: Long,
    val originalName: String,
    /** Includes the leading dot. */
    val ext: String,
    val fileSize: Int,
    val md5: String?,
    val width: Int,
    val height: Int,
    val thumbWidth: Int,
    val thumbHeight: Int,
    val isSpoiler: Boolean,
    val customSpoiler: Int?,
    val isDeleted: Boolean,
) {
    val displayName: String get() = originalName + ext

    /** The only video container 4chan accepts, and the one Android plays fine. */
    val isWebM: Boolean get() = ext.equals(".webm", ignoreCase = true)

    val isDisplayableImage: Boolean
        get() = ext.lowercase() in listOf(".jpg", ".jpeg", ".png", ".gif")

    val dimensionsText: String get() = "${width}×${height}"
}

/**
 * A single post.
 *
 * 4chan uses one JSON shape for the opening post of a thread and for every
 * reply — `resto == 0` marks the OP, and a handful of fields are only ever
 * populated on it. One type rather than an OP/reply hierarchy avoids casting
 * noise at every call site.
 */
data class Post(
    val no: Int,
    val resto: Int,
    val time: Long,
    val name: String,
    val trip: String?,
    /** Per-thread poster ID. /pol/ has these enabled. */
    val posterId: String?,
    val capcode: Capcode,
    val since4Pass: Int?,
    val country: String?,
    val countryName: String?,
    val boardFlag: String?,
    val flagName: String?,
    val subject: String?,
    /** The site's small HTML subset. Never render directly — use CommentMarkup. */
    val comment: String?,
    val attachment: Attachment?,
    val replyCount: Int?,
    val imageCount: Int?,
    val uniqueIps: Int?,
    val isSticky: Boolean,
    val isClosed: Boolean,
    val isArchived: Boolean,
    val hitBumpLimit: Boolean,
    val hitImageLimit: Boolean,
) {
    val isOp: Boolean get() = resto == 0
    val threadNo: Int get() = if (resto == 0) no else resto

    val isAnonymous: Boolean
        get() = trip.isNullOrEmpty() && (name == "Anonymous" || name.isEmpty()) &&
            capcode.label == null

    companion object {
        /** Returns null when the object has no usable post number. */
        fun from(json: JSONObject): Post? {
            val no = json.int("no") ?: return null
            val tim = json.int("tim")?.toLong() ?: json.optLong("tim", 0L)
            val ext = json.nonBlank("ext")
            val attachment = if (tim > 0 && ext != null) {
                Attachment(
                    tim = tim,
                    originalName = json.str("filename") ?: "",
                    ext = ext,
                    fileSize = json.int("fsize") ?: 0,
                    md5 = json.nonBlank("md5"),
                    width = json.int("w") ?: 0,
                    height = json.int("h") ?: 0,
                    thumbWidth = json.int("tn_w") ?: 0,
                    thumbHeight = json.int("tn_h") ?: 0,
                    isSpoiler = json.flag("spoiler"),
                    customSpoiler = json.int("custom_spoiler"),
                    isDeleted = json.flag("filedeleted"),
                )
            } else {
                null
            }

            return Post(
                no = no,
                resto = json.int("resto") ?: 0,
                time = json.epoch("time") ?: 0L,
                name = json.nonBlank("name") ?: "Anonymous",
                trip = json.nonBlank("trip"),
                posterId = json.nonBlank("id"),
                capcode = Capcode.from(json.str("capcode")),
                since4Pass = json.int("since4pass"),
                country = json.nonBlank("country"),
                countryName = json.nonBlank("country_name"),
                boardFlag = json.nonBlank("board_flag"),
                flagName = json.nonBlank("flag_name"),
                subject = json.nonBlank("sub"),
                comment = json.nonBlank("com"),
                attachment = attachment,
                replyCount = json.int("replies"),
                imageCount = json.int("images"),
                uniqueIps = json.int("unique_ips"),
                isSticky = json.flag("sticky"),
                isClosed = json.flag("closed"),
                isArchived = json.flag("archived"),
                hitBumpLimit = json.flag("bumplimit"),
                hitImageLimit = json.flag("imagelimit"),
            )
        }
    }
}

/** One thread in the catalog: the OP inline, plus a few preview replies. */
data class CatalogThread(
    val op: Post,
    val lastReplies: List<Post>,
    val omittedPosts: Int,
    val omittedImages: Int,
    val lastModified: Long?,
) {
    val replyCount: Int get() = op.replyCount ?: (omittedPosts + lastReplies.size)
    val imageCount: Int get() = op.imageCount ?: omittedImages

    companion object {
        fun from(json: JSONObject): CatalogThread? {
            val op = Post.from(json) ?: return null
            val replies = mutableListOf<Post>()
            json.optJSONArray("last_replies")?.let { array ->
                for (i in 0 until array.length()) {
                    array.optJSONObject(i)?.let { Post.from(it) }?.let(replies::add)
                }
            }
            return CatalogThread(
                op = op,
                lastReplies = replies,
                omittedPosts = json.int("omitted_posts") ?: 0,
                omittedImages = json.int("omitted_images") ?: 0,
                lastModified = json.epoch("last_modified"),
            )
        }
    }
}

object Parsing {
    /** `/{board}/thread/{no}.json` — the whole thread, every post, one request. */
    fun threadPosts(body: String): List<Post> {
        val posts = mutableListOf<Post>()
        val array = JSONObject(body).optJSONArray("posts") ?: return posts
        for (i in 0 until array.length()) {
            array.optJSONObject(i)?.let { Post.from(it) }?.let(posts::add)
        }
        return posts
    }

    /**
     * `catalog.json` — every page of the board in one response, flattened in
     * page order, which is the board's own bump order.
     */
    fun catalogThreads(body: String): List<CatalogThread> {
        val result = mutableListOf<CatalogThread>()
        val pages = JSONArray(body)
        for (p in 0 until pages.length()) {
            val threads = pages.optJSONObject(p)?.optJSONArray("threads") ?: continue
            for (t in 0 until threads.length()) {
                threads.optJSONObject(t)?.let { CatalogThread.from(it) }?.let(result::add)
            }
        }
        return result
    }
}
