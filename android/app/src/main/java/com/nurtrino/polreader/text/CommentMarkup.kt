package com.nurtrino.polreader.text

/**
 * The output of parsing a comment body.
 *
 * Blocks rather than one string: a code block scrolls horizontally on its own,
 * independently of the paragraphs around it, which a single styled string
 * cannot express.
 */
sealed interface CommentBlock {
    data class Paragraph(val text: String, val spans: List<CommentSpan>) : CommentBlock
    data class Code(val text: String) : CommentBlock
}

/**
 * A styled range, in character offsets into the paragraph's text.
 *
 * These are Kotlin `String` indices, i.e. UTF-16 code units. The Swift port
 * measures in grapheme clusters. The two disagree for astral-plane characters,
 * which is fine — offsets are produced and consumed entirely within one
 * platform and never cross between them.
 */
data class CommentSpan(val start: Int, val length: Int, val style: CommentStyle) {
    val end: Int get() = start + length
}

sealed interface CommentStyle {
    object Italic : CommentStyle
    object Bold : CommentStyle
    object Underline : CommentStyle

    /** 4chan's `<s>`: blacked out until tapped. */
    object Spoiler : CommentStyle

    /** `<span class="quote">`, the `>greentext` convention. */
    object Greentext : CommentStyle

    /** A quoted post that no longer exists. */
    object Deadlink : CommentStyle

    object InlineCode : CommentStyle

    /** Shift-JIS art, which only lines up in a monospaced font. */
    object ShiftJis : CommentStyle

    data class Link(val url: String) : CommentStyle

    /**
     * A `>>123` reference. [board] and [thread] are null when the target is in
     * the thread being read, which is the overwhelmingly common case.
     */
    data class Quotelink(val board: String?, val thread: Int?, val post: Int) : CommentStyle

    /** A `>>>/g/` reference to a board rather than a post. */
    data class BoardLink(val board: String) : CommentStyle
}

/**
 * The 4chan comment parser.
 *
 * A direct transliteration of `ios/PolReader/Text/CommentMarkup.swift`, which
 * is itself proven against `tools/comment_parser_reference.py` and its
 * assertions in `tools/test_parser.py`. Change one, change all three.
 *
 * 4chan's `com` field is a small, fixed HTML subset:
 *
 *     <br>                                    line break
 *     <span class="quote">&gt;text</span>     greentext
 *     <a href="#p123" class="quotelink">      reply link within the thread
 *     <a href="/pol/thread/1#p2" ...>         cross-thread link
 *     <a href="//boards.4chan.org/g/" ...>    cross-board link
 *     <span class="deadlink">                 quoted post that is gone
 *     <s>text</s>                             spoiler
 *     <pre class="prettyprint">               code block
 *     <span class="sjis">                     Shift-JIS art
 *     <wbr>                                   word-break hint
 *     <b> <strong> <i> <em> <u>               emphasis
 *     &gt; &lt; &amp; &#039; &#x27;            entities
 */
object CommentMarkup {

    // --- Entities -----------------------------------------------------------

    private val namedEntities = mapOf(
        "lt" to '<', "gt" to '>', "amp" to '&', "quot" to '"', "apos" to '\'',
        "nbsp" to ' ', "ndash" to '–', "mdash" to '—',
        "hellip" to '…', "laquo" to '«', "raquo" to '»',
        "ldquo" to '“', "rdquo" to '”', "lsquo" to '‘', "rsquo" to '’',
        "deg" to '°', "middot" to '·', "bull" to '•',
        "trade" to '™', "copy" to '©', "reg" to '®',
        "eacute" to 'é', "egrave" to 'è', "uuml" to 'ü',
        "ouml" to 'ö', "auml" to 'ä', "szlig" to 'ß',
        "ccedil" to 'ç', "ntilde" to 'ñ', "pound" to '£',
        "euro" to '€', "yen" to '¥', "sect" to '§', "para" to '¶',
        "times" to '×', "divide" to '÷', "plusmn" to '±',
        "frac12" to '½', "frac14" to '¼', "sup2" to '²', "sup3" to '³',
    )

    /**
     * A bare `&` in prose is common. Without a bound on the lookahead, the scan
     * for the closing `;` swallows the rest of the line.
     */
    private const val MAX_ENTITY_LENGTH = 12

    private data class Decoded(val char: Char, val next: Int)

    private fun decodeEntity(s: String, i: Int): Decoded? {
        val limit = minOf(s.length, i + MAX_ENTITY_LENGTH + 2)
        var semi = -1
        var j = i + 1
        while (j < limit) {
            val c = s[j]
            if (c == ';') {
                semi = j
                break
            }
            // Entities are alphanumeric, plus a leading '#'. Anything else
            // means this '&' was just an ampersand.
            if (!(c.isLetterOrDigit() || (c == '#' && j == i + 1))) return null
            j++
        }
        if (semi <= i + 1) return null

        val body = s.substring(i + 1, semi)
        if (body.startsWith("#")) {
            val digits = body.substring(1)
            val code = if (digits.startsWith("x", ignoreCase = true)) {
                digits.substring(1).toIntOrNull(16)
            } else {
                digits.toIntOrNull(10)
            } ?: return null
            if (code <= 0 || code > 0x10FFFF || code in 0xD800..0xDFFF) return null
            // Only BMP scalars fit a single Char; anything above is dropped
            // rather than producing a broken surrogate half.
            if (code > 0xFFFF) return null
            return Decoded(code.toChar(), semi + 1)
        }

        val mapped = namedEntities[body] ?: return null
        return Decoded(mapped, semi + 1)
    }

    /** Decode every entity in a plain string. Used for `href` attributes. */
    fun decodeEntities(s: String): String {
        if (!s.contains('&')) return s
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            if (s[i] == '&') {
                val decoded = decodeEntity(s, i)
                if (decoded != null) {
                    out.append(decoded.char)
                    i = decoded.next
                    continue
                }
            }
            out.append(s[i])
            i++
        }
        return out.toString()
    }

    // --- Tag scanning -------------------------------------------------------

    private data class Tag(
        val name: String,
        val attributes: Map<String, String>,
        val isClosing: Boolean,
        val endIndex: Int,
    )

    /**
     * Parse the tag starting at `s[i] == '<'`, or return null when this `<` is
     * not the start of a tag and must be treated as literal text.
     *
     * The guard on the character after `<` is what stops `a < b and c > d` from
     * being read as a tag and swallowing everything up to the `>`.
     */
    private fun parseTag(s: String, i: Int): Tag? {
        val n = s.length
        if (i + 1 >= n) return null
        val isClosing = s[i + 1] == '/'
        if (isClosing) {
            if (i + 2 >= n || !s[i + 2].isLetter()) return null
        } else if (!s[i + 1].isLetter()) {
            return null
        }

        var j = if (isClosing) i + 2 else i + 1
        val nameStart = j
        while (j < n && (s[j].isLetterOrDigit() || s[j] == '-' || s[j] == '_')) j++
        val name = s.substring(nameStart, j).lowercase()
        if (name.isEmpty()) return null

        val attributes = mutableMapOf<String, String>()
        while (j < n) {
            while (j < n && s[j].isWhitespace()) j++
            if (j >= n) return null
            if (s[j] == '>') return Tag(name, attributes, isClosing, j + 1)
            if (s[j] == '/') {
                j++
                continue
            }

            val attrStart = j
            while (j < n && !s[j].isWhitespace() && s[j] != '=' && s[j] != '>') j++
            val attrName = s.substring(attrStart, j).lowercase()
            while (j < n && s[j].isWhitespace()) j++

            var value = ""
            if (j < n && s[j] == '=') {
                j++
                while (j < n && s[j].isWhitespace()) j++
                if (j < n && (s[j] == '"' || s[j] == '\'')) {
                    val quote = s[j]
                    j++
                    val valueStart = j
                    while (j < n && s[j] != quote) j++
                    value = s.substring(valueStart, minOf(j, n))
                    j++
                } else {
                    val valueStart = j
                    while (j < n && !s[j].isWhitespace() && s[j] != '>') j++
                    value = s.substring(valueStart, j)
                }
            }
            if (attrName.isNotEmpty()) attributes[attrName] = value
        }
        // Ran off the end without a '>': not a tag.
        return null
    }

    // --- Link classification ------------------------------------------------

    private val safeSchemes = listOf("http://", "https://")
    private val boardHosts = listOf("boards.4chan.org", "boards.4channel.org")

    /**
     * Turn an `<a>` into a style, or null if the link should be dropped while
     * keeping its text.
     *
     * Quotelinks are recognised by shape *before* any scheme check, because
     * their hrefs are relative (`#p123`, `/pol/thread/1#p2`) and would
     * otherwise fail an http(s) allowlist. That allowlist exists because a
     * comment body is entirely untrusted input, and `javascript:` must never
     * become a tappable link.
     */
    fun classifyHref(rawHref: String?, classes: List<String>): CommentStyle? {
        val href = decodeEntities(rawHref ?: "").trim()
        if (href.isEmpty()) return null

        val isQuotelink = classes.contains("quotelink")

        if (href.startsWith("#p")) {
            val digits = href.substring(2)
            val post = digits.toIntOrNull()
            return if (digits.isNotEmpty() && digits.all { it.isDigit() } && post != null) {
                CommentStyle.Quotelink(null, null, post)
            } else {
                null
            }
        }

        var path = href
        var host: String? = null

        if (path.startsWith("//")) {
            val rest = path.substring(2)
            val slash = rest.indexOf('/')
            if (slash >= 0) {
                host = rest.substring(0, slash)
                path = rest.substring(slash)
            } else {
                host = rest
                path = "/"
            }
        } else {
            for (scheme in safeSchemes) {
                if (href.lowercase().startsWith(scheme)) {
                    val rest = path.substring(scheme.length)
                    val slash = rest.indexOf('/')
                    val candidateHost = if (slash >= 0) rest.substring(0, slash) else rest
                    val candidatePath = if (slash >= 0) rest.substring(slash) else "/"
                    if (boardHosts.contains(candidateHost)) {
                        host = candidateHost
                        path = candidatePath
                    }
                    break
                }
            }
        }

        if (host == null && !path.startsWith("/")) {
            val low = href.lowercase()
            return if (safeSchemes.any { low.startsWith(it) }) CommentStyle.Link(href) else null
        }

        if (host != null && !boardHosts.contains(host)) {
            val low = href.lowercase()
            return if (safeSchemes.any { low.startsWith(it) }) CommentStyle.Link(href) else null
        }

        val parts = path.split("/").filter { it.isNotEmpty() }
        val board = parts.firstOrNull() ?: return null
        if (parts.size == 1) return CommentStyle.BoardLink(board)

        if (parts.size >= 3 && parts[1] == "thread") {
            var tail = parts[2]
            var anchor: String? = null
            val hash = tail.indexOf("#p")
            if (hash >= 0) {
                anchor = tail.substring(hash + 2)
                tail = tail.substring(0, hash)
            }
            if (tail.isEmpty() || !tail.all { it.isDigit() }) return null
            val threadNo = tail.toIntOrNull() ?: return null
            val postNo = anchor?.takeIf { it.isNotEmpty() && it.all { c -> c.isDigit() } }
                ?.toIntOrNull() ?: threadNo
            return CommentStyle.Quotelink(board, threadNo, postNo)
        }

        if (isQuotelink) return CommentStyle.BoardLink(board)
        val low = href.lowercase()
        return if (safeSchemes.any { low.startsWith(it) }) CommentStyle.Link(href) else null
    }

    private fun classifySpan(classes: List<String>): CommentStyle? = when {
        classes.contains("quote") -> CommentStyle.Greentext
        classes.contains("deadlink") -> CommentStyle.Deadlink
        classes.contains("sjis") -> CommentStyle.ShiftJis
        else -> null
    }

    // --- Parsing ------------------------------------------------------------

    private val emphasis = mapOf(
        "b" to CommentStyle.Bold, "strong" to CommentStyle.Bold,
        "i" to CommentStyle.Italic, "em" to CommentStyle.Italic,
        "u" to CommentStyle.Underline,
        "s" to CommentStyle.Spoiler, "strike" to CommentStyle.Spoiler,
        "del" to CommentStyle.Spoiler,
        "code" to CommentStyle.InlineCode,
    )

    /**
     * A closing tag pops the innermost element opened by the *same group*, not
     * the innermost element with a matching style. Matching on style cannot
     * work: an element may carry no style at all (an unknown `<span>`, or an
     * `<a>` whose href was rejected), and those still have to be popped by
     * their closing tag or they leak up the stack and corrupt every range that
     * follows.
     */
    private val closeGroup = mapOf(
        "strong" to "b", "em" to "i", "strike" to "s", "del" to "s",
    )

    private fun groupFor(tagName: String) = closeGroup[tagName] ?: tagName

    private val blockBreaking = setOf("p", "div")

    private data class OpenElement(val group: String, val style: CommentStyle?, var start: Int)

    fun parse(html: String?): List<CommentBlock> {
        if (html.isNullOrEmpty()) return emptyList()

        val blocks = mutableListOf<CommentBlock>()
        val text = StringBuilder()
        val spans = mutableListOf<CommentSpan>()
        val open = mutableListOf<OpenElement>()

        // Trim surrounding whitespace and shift the spans to match, or every
        // range drifts by the number of leading spaces removed.
        fun emit(raw: String, rawSpans: List<CommentSpan>) {
            var lead = 0
            while (lead < raw.length && raw[lead].isWhitespace()) lead++
            var trail = raw.length
            while (trail > lead && raw[trail - 1].isWhitespace()) trail--
            if (trail <= lead) return  // whitespace-only paragraph

            val trimmed = raw.substring(lead, trail)
            val shifted = mutableListOf<CommentSpan>()
            for (span in rawSpans) {
                val start = maxOf(0, span.start - lead)
                val end = minOf(trimmed.length, span.end - lead)
                if (end > start) shifted.add(CommentSpan(start, end - start, span.style))
            }
            shifted.sortWith(compareBy({ it.start }, { it.length }))
            blocks.add(CommentBlock.Paragraph(trimmed, shifted))
        }

        // Close every open style at the end of the line, then reopen it at the
        // start of the next one, so emphasis survives a <br> without producing
        // a span that runs past the end of its own paragraph.
        fun flushParagraph() {
            val length = text.length
            for (element in open) {
                val style = element.style
                if (style != null && length > element.start) {
                    spans.add(CommentSpan(element.start, length - element.start, style))
                }
            }
            emit(text.toString(), spans.toList())
            text.setLength(0)
            spans.clear()
            for (element in open) element.start = 0
        }

        fun closeGroupNamed(name: String) {
            for (index in open.indices.reversed()) {
                val element = open[index]
                if (element.group != name) continue
                val length = text.length - element.start
                val style = element.style
                if (style != null && length > 0) {
                    spans.add(CommentSpan(element.start, length, style))
                }
                open.removeAt(index)
                return
            }
        }

        var i = 0
        val n = html.length
        while (i < n) {
            val c = html[i]

            if (c == '<') {
                val tag = parseTag(html, i)
                if (tag == null) {
                    text.append('<')  // stray '<' in prose
                    i++
                    continue
                }
                i = tag.endIndex

                when (tag.name) {
                    // A word-break hint. It must vanish leaving nothing behind:
                    // 4chan injects it into long URLs and filenames, and
                    // inserting any character here corrupts them.
                    "wbr" -> continue

                    "br" -> {
                        flushParagraph()
                        continue
                    }

                    "pre" -> {
                        if (!tag.isClosing) {
                            flushParagraph()
                            val (codeText, next) = readCodeBlock(html, i)
                            i = next
                            if (codeText.any { !it.isWhitespace() }) {
                                blocks.add(CommentBlock.Code(codeText))
                            }
                        }
                        continue
                    }

                    "a" -> {
                        if (tag.isClosing) {
                            closeGroupNamed("a")
                        } else {
                            val classes = (tag.attributes["class"] ?: "").lowercase()
                                .split(" ").filter { it.isNotEmpty() }
                            // A rejected href opens with no style: the anchor
                            // text still belongs in the output, only the link
                            // goes away.
                            open.add(
                                OpenElement("a", classifyHref(tag.attributes["href"], classes), text.length)
                            )
                        }
                        continue
                    }

                    "span" -> {
                        if (tag.isClosing) {
                            closeGroupNamed("span")
                        } else {
                            val classes = (tag.attributes["class"] ?: "").lowercase()
                                .split(" ").filter { it.isNotEmpty() }
                            open.add(OpenElement("span", classifySpan(classes), text.length))
                        }
                        continue
                    }

                    else -> {
                        if (blockBreaking.contains(tag.name)) {
                            flushParagraph()
                            continue
                        }
                        val style = emphasis[tag.name]
                        if (style != null) {
                            if (tag.isClosing) {
                                closeGroupNamed(groupFor(tag.name))
                            } else {
                                open.add(OpenElement(groupFor(tag.name), style, text.length))
                            }
                        }
                        // Unknown tag: drop the tag, keep the text inside it.
                        continue
                    }
                }
            }

            if (c == '&') {
                val decoded = decodeEntity(html, i)
                if (decoded != null) {
                    text.append(decoded.char)
                    i = decoded.next
                    continue
                }
                text.append('&')
                i++
                continue
            }

            if (c == '\r') {
                i++
                continue
            }
            if (c == '\n') {
                flushParagraph()
                i++
                continue
            }

            text.append(c)
            i++
        }

        // Close whatever is still open at the end of the body.
        val length = text.length
        for (element in open) {
            val style = element.style
            if (style != null && length > element.start) {
                spans.add(CommentSpan(element.start, length - element.start, style))
            }
        }
        emit(text.toString(), spans.toList())

        return blocks
    }

    /** Consume up to and including the matching `</pre>`. */
    private fun readCodeBlock(html: String, start: Int): Pair<String, Int> {
        val out = StringBuilder()
        var i = start
        val n = html.length
        while (i < n) {
            if (html[i] == '<') {
                val tag = parseTag(html, i)
                if (tag != null) {
                    if (tag.name == "pre" && tag.isClosing) return out.toString() to tag.endIndex
                    if (tag.name == "br") out.append('\n')
                    // Any other markup inside a code block is dropped, its text kept.
                    i = tag.endIndex
                    continue
                }
                out.append('<')
                i++
                continue
            }
            if (html[i] == '&') {
                val decoded = decodeEntity(html, i)
                if (decoded != null) {
                    out.append(decoded.char)
                    i = decoded.next
                    continue
                }
            }
            out.append(html[i])
            i++
        }
        return out.toString() to i
    }

    // --- Quotelink extraction -----------------------------------------------

    /**
     * Every post number this comment quotes, in order, without duplicates.
     *
     * Runs the full parser rather than a regex over `>>\d+`, so that a `>>123`
     * inside a code block, or inside a link that was rejected, does not
     * register as a reply and pollute the backlink index.
     */
    fun quotedPostNumbers(html: String?): List<Int> {
        val seen = mutableListOf<Int>()
        for (block in parse(html)) {
            if (block !is CommentBlock.Paragraph) continue
            for (span in block.spans) {
                val style = span.style
                if (style is CommentStyle.Quotelink && style.board == null && style.post !in seen) {
                    seen.add(style.post)
                }
            }
        }
        return seen
    }

    /** Plain text of a comment, for filtering and previews. */
    fun plainText(html: String?): String =
        parse(html).joinToString("\n") { block ->
            when (block) {
                is CommentBlock.Paragraph -> block.text
                is CommentBlock.Code -> block.text
            }
        }
}

/**
 * Parsed-comment cache.
 *
 * Threads re-render constantly while scrolling and collapsing, and re-parsing
 * on every pass is the difference between smooth and stuttery.
 */
object CommentParserCache {
    private const val LIMIT = 3000
    private val cache = object : LinkedHashMap<String, List<CommentBlock>>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<CommentBlock>>) =
            size > LIMIT
    }

    @Synchronized
    fun blocks(html: String?): List<CommentBlock> {
        if (html.isNullOrEmpty()) return emptyList()
        cache[html]?.let { return it }
        val parsed = CommentMarkup.parse(html)
        cache[html] = parsed
        return parsed
    }

    @Synchronized
    fun clear() = cache.clear()
}
