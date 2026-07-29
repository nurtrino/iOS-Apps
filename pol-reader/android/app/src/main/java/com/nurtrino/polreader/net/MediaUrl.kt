package com.nurtrino.polreader.net

import com.nurtrino.polreader.model.Attachment

/**
 * URL construction for everything that is not the JSON API.
 *
 * 4chan splits its content across three hosts, and the paths are the part of
 * the API most easily got subtly wrong — board flags in particular do *not*
 * live under the country-flag path.
 */
object MediaUrl {

    private const val MEDIA = "https://i.4cdn.org"
    private const val STATIC = "https://s.4cdn.org"
    private const val BOARDS = "https://boards.4chan.org"

    /**
     * The full-size upload. Addressed by `tim`, the upload timestamp — never by
     * the original filename, which is display-only and frequently not unique.
     */
    fun file(board: String, attachment: Attachment): String =
        "$MEDIA/$board/${attachment.tim}${attachment.ext}"

    /** The thumbnail — always `.jpg` regardless of the source file's type. */
    fun thumbnail(board: String, attachment: Attachment): String =
        "$MEDIA/$board/${attachment.tim}s.jpg"

    /** A geolocated country flag. */
    fun countryFlag(code: String): String? {
        val cleaned = code.lowercase().trim()
        return if (cleaned.isEmpty()) null else "$STATIC/image/country/$cleaned.gif"
    }

    /**
     * A board flag — on /pol/, the user-selectable flags shown instead of a
     * country. Note the path is `/image/flags/<board>/`, not the country path.
     * Getting this wrong yields a silent 404 on every flagged post.
     */
    fun boardFlag(board: String, code: String): String? {
        val cleaned = code.lowercase().trim()
        return if (cleaned.isEmpty()) null else "$STATIC/image/flags/$board/$cleaned.gif"
    }

    /** The spoiler placeholder shown in place of a spoilered thumbnail. */
    fun spoiler(board: String, customSpoiler: Int?): String =
        if (customSpoiler != null && customSpoiler > 0) {
            "$STATIC/image/spoiler-$board$customSpoiler.png"
        } else {
            "$STATIC/image/spoiler.png"
        }

    /**
     * The thread on the website. The app is read-only, so anything needing an
     * account leaves for the site.
     */
    fun webThread(board: String, threadNo: Int, postNo: Int? = null): String =
        if (postNo != null && postNo != threadNo) {
            "$BOARDS/$board/thread/$threadNo#p$postNo"
        } else {
            "$BOARDS/$board/thread/$threadNo"
        }

    fun webBoard(board: String): String = "$BOARDS/$board/"
}
