package com.nurtrino.dispatch.core

/** Markup to text, and the pieces of markup worth pulling out of a feed. */
object HtmlText {

    private val OPAQUE = listOf("script", "style", "noscript", "iframe", "svg", "form")

    /**
     * Plain text for a row.
     *
     * Source newlines are flattened to spaces *before* tags are stripped. They are
     * insignificant whitespace in HTML, and treating them as line breaks puts one
     * in the middle of every sentence of an eighty-column feed.
     */
    fun plainText(html: String): String {
        var text = removeOpaqueSections(html)
        text = text.replace('\n', ' ').replace('\r', ' ')
        text = Regex("<(br|/p|/div|/li|/h[1-6])[^>]*>", RegexOption.IGNORE_CASE).replace(text, "\n")
        text = stripTags(text)
        text = decodeEntities(text)
        return collapseWhitespace(text)
    }

    /**
     * Removes a tag and its contents.
     *
     * Matched on the whole tag name, not a prefix: removing `<script>` by prefix
     * also removes `<section>`, which deletes the body of any site that wraps its
     * content in one.
     */
    fun removeOpaqueSections(html: String): String {
        var text = html
        for (tag in OPAQUE) {
            text = Regex("<$tag\\b[^>]*>.*?</$tag\\s*>",
                setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).replace(text, " ")
            text = Regex("<$tag\\b[^>]*/>", RegexOption.IGNORE_CASE).replace(text, " ")
        }
        return text
    }

    fun stripTags(html: String): String = Regex("<[^>]*>").replace(html, "")

    fun collapseWhitespace(text: String): String {
        val lines = text.split('\n')
            .map { Regex("[ \\t]+").replace(it, " ").trim() }
        val out = ArrayList<String>()
        for (line in lines) {
            if (line.isEmpty() && (out.isEmpty() || out.last().isEmpty())) continue
            out.add(line)
        }
        return out.joinToString("\n").trim()
    }

    fun decodeEntities(text: String): String {
        if (!text.contains('&')) return text
        val out = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val character = text[index]
            if (character != '&') {
                out.append(character)
                index++
                continue
            }
            val semicolon = text.indexOf(';', index + 1)
            if (semicolon < 0 || semicolon - index > 12) {
                out.append(character)
                index++
                continue
            }
            val name = text.substring(index + 1, semicolon)
            val replacement = when {
                name == "amp" -> "&"
                name == "lt" -> "<"
                name == "gt" -> ">"
                name == "quot" -> "\""
                name == "apos" || name == "#39" -> "'"
                name.startsWith("#x") || name.startsWith("#X") ->
                    name.substring(2).toIntOrNull(16)?.let { String(Character.toChars(it)) }
                name.startsWith("#") ->
                    name.substring(1).toIntOrNull()?.let { String(Character.toChars(it)) }
                // The named HTML entities, from the sanitizer's table. Body text
                // that reached here without going through the XML parser still
                // has "&rsquo;" in it, and printing that literally in a headline
                // is the visible half of this bug.
                else -> XmlSanitizer.NAMED[name]?.takeIf { it > 0 }
                    ?.let { String(Character.toChars(it)) }
            }
            if (replacement == null) {
                out.append(character)
                index++
            } else {
                out.append(replacement)
                index = semicolon + 1
            }
        }
        return out.toString()
    }

    /**
     * The first real image in a body.
     *
     * `data-src` is preferred over `src`, because most WordPress themes put a grey
     * placeholder in `src` and the real photo in `data-src` — reading `src` alone
     * gets a blank image in every row.
     */
    fun firstImageUrl(html: String): String? {
        val tag = Regex("<img\\b[^>]*>", RegexOption.IGNORE_CASE).find(html)?.value ?: return null
        for (attribute in listOf("data-src", "data-lazy-src", "data-original", "src")) {
            val value = attributeValue(tag, attribute)
            if (value != null && !value.startsWith("data:")) return value
        }
        return null
    }

    fun attributeValue(tag: String, name: String): String? {
        val match = Regex("$name\\s*=\\s*[\"']([^\"']*)[\"']", RegexOption.IGNORE_CASE).find(tag)
        return match?.groupValues?.get(1)?.takeIf { it.isNotEmpty() }
    }

    /**
     * The outbound link in an aggregator's own description.
     *
     * A link aggregator's feed item points at its own permalink; the article is one
     * hop further on. Links to the aggregator's own host are excluded, as are share
     * links, and a "Go To Article" style label wins outright.
     */
    fun outboundLink(html: String, excludingHost: String?): String? {
        val links = Regex("<a\\b[^>]*>(.*?)</a>",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).findAll(html)

        var firstCandidate: String? = null
        for (match in links) {
            val tag = match.value.substringBefore('>') + ">"
            val href = attributeValue(tag, "href") ?: continue
            if (!href.startsWith("http")) continue

            val host = hostOf(href) ?: continue
            if (excludingHost != null && hostsMatch(host, excludingHost)) continue
            if (SHARE_HOSTS.any { hostsMatch(host, it) }) continue

            val label = plainText(match.groupValues[1]).lowercase()
            if (LABEL_HINTS.any { label.contains(it) }) return href
            if (firstCandidate == null) firstCandidate = href
        }
        return firstCandidate
    }

    private val SHARE_HOSTS = listOf(
        "facebook.com", "twitter.com", "x.com", "t.me", "reddit.com",
        "linkedin.com", "pinterest.com", "gettr.com", "truthsocial.com",
    )

    private val LABEL_HINTS = listOf("go to article", "read the full", "read more at", "source:")

    fun hostOf(url: String): String? {
        val withoutScheme = url.substringAfter("//", "")
        if (withoutScheme.isEmpty()) return null
        val host = withoutScheme.substringBefore('/').substringBefore('?').lowercase()
        return host.ifEmpty { null }
    }

    private fun hostsMatch(left: String, right: String): Boolean {
        val a = left.removePrefix("www.")
        val b = right.removePrefix("www.")
        return a == b || a.endsWith(".$b") || b.endsWith(".$a")
    }
}
