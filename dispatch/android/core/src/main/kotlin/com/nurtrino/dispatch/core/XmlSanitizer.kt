package com.nurtrino.dispatch.core

/**
 * Repairs the XML news feeds actually serve.
 *
 * This is the single highest-value file in either app, and it is not glamorous.
 * A strict XML parser aborts on the first undefined entity and returns nothing,
 * and a reader that returns nothing looks exactly like a source that has gone
 * quiet. Every rule here is a real feed that otherwise produces an empty section.
 */
object XmlSanitizer {

    /**
     * Entities HTML defines and XML does not. XML's own five map to -1, meaning
     * "leave alone".
     *
     * Not private: `HtmlText.decodeEntities` needs the same table. A feed body
     * that reaches the text layer without passing through the XML parser still
     * contains `&rsquo;`, and a second copy of fifty entities is a second copy to
     * forget to update.
     */
    val NAMED = mapOf(
        "nbsp" to 160, "iexcl" to 161, "cent" to 162, "pound" to 163, "curren" to 164,
        "yen" to 165, "brvbar" to 166, "sect" to 167, "uml" to 168, "copy" to 169,
        "ordf" to 170, "laquo" to 171, "not" to 172, "shy" to 173, "reg" to 174,
        "macr" to 175, "deg" to 176, "plusmn" to 177, "sup2" to 178, "sup3" to 179,
        "acute" to 180, "micro" to 181, "para" to 182, "middot" to 183, "cedil" to 184,
        "sup1" to 185, "ordm" to 186, "raquo" to 187, "frac14" to 188, "frac12" to 189,
        "frac34" to 190, "iquest" to 191, "times" to 215, "divide" to 247,
        "ndash" to 8211, "mdash" to 8212, "lsquo" to 8216, "rsquo" to 8217,
        "sbquo" to 8218, "ldquo" to 8220, "rdquo" to 8221, "bdquo" to 8222,
        "dagger" to 8224, "Dagger" to 8225, "bull" to 8226, "hellip" to 8230,
        "permil" to 8240, "prime" to 8242, "Prime" to 8243, "lsaquo" to 8249,
        "rsaquo" to 8250, "oline" to 8254, "frasl" to 8260, "euro" to 8364,
        "trade" to 8482, "larr" to 8592, "uarr" to 8593, "rarr" to 8594,
        "darr" to 8595, "harr" to 8596, "spades" to 9824, "clubs" to 9827,
        "hearts" to 9829, "diams" to 9830, "aacute" to 225, "eacute" to 233,
        "iacute" to 237, "oacute" to 243, "uacute" to 250, "ntilde" to 241,
        "uuml" to 252, "ouml" to 246, "auml" to 228, "szlig" to 223,
        "egrave" to 232, "agrave" to 224, "ccedil" to 231, "amp" to -1,
        "lt" to -1, "gt" to -1, "quot" to -1, "apos" to -1,
    )

    /** An entity name is short. A semicolon far away is punctuation, not a terminator. */
    private const val MAX_ENTITY = 12

    fun sanitize(text: String): String {
        var out = text
        if (out.startsWith("\uFEFF")) out = out.substring(1)
        out = rewriteDeclaredEncoding(out)
        return rewriteEntities(out)
    }

    /**
     * The declaration is rewritten to UTF-8 rather than obeyed.
     *
     * By the time this runs the bytes have already been decoded, so a
     * declaration saying ISO-8859-1 makes a strict parser reject its own input.
     */
    private fun rewriteDeclaredEncoding(text: String): String {
        val end = text.indexOf("?>")
        if (!text.startsWith("<?xml") || end < 0) return text
        val declaration = text.substring(0, end)
        if (!declaration.contains("encoding")) return text
        val fixed = Regex("encoding\\s*=\\s*\"[^\"]*\"")
            .replace(declaration, "encoding=\"UTF-8\"")
        return fixed + text.substring(end)
    }

    fun rewriteEntities(text: String): String {
        val out = StringBuilder(text.length + 16)
        var index = 0
        while (index < text.length) {
            val character = text[index]

            // Characters XML forbids outright. A feed with a stray 0x0B in it
            // fails to parse with a message about the document, not the byte.
            if (character.code < 0x20 && character != '\n' && character != '\r' && character != '\t') {
                index++
                continue
            }

            if (character != '&') {
                out.append(character)
                index++
                continue
            }

            val semicolon = text.indexOf(';', index + 1)
            val name = if (semicolon > index && semicolon - index - 1 <= MAX_ENTITY) {
                text.substring(index + 1, semicolon)
            } else {
                null
            }

            if (name == null) {
                out.append("&amp;")
                index++
                continue
            }

            if (name.startsWith("#")) {
                val code = numericValue(name)
                if (code == null || !isAllowed(code)) {
                    // A reference to a character XML forbids is dropped whole.
                    index = semicolon + 1
                    continue
                }
                out.append('&').append(name).append(';')
                index = semicolon + 1
                continue
            }

            val mapped = NAMED[name]
            when {
                mapped == null -> {
                    // Unknown: keep the text, lose the ampersand, so the document
                    // parses and the words survive.
                    out.append("&amp;").append(name).append(';')
                }
                mapped < 0 -> out.append('&').append(name).append(';')
                else -> out.append("&#").append(mapped).append(';')
            }
            index = semicolon + 1
        }
        return out.toString()
    }

    private fun numericValue(name: String): Int? {
        val body = name.substring(1)
        return if (body.startsWith("x") || body.startsWith("X")) {
            body.substring(1).toIntOrNull(16)
        } else {
            body.toIntOrNull()
        }
    }

    private fun isAllowed(code: Int): Boolean =
        code == 0x9 || code == 0xA || code == 0xD ||
            (code in 0x20..0xD7FF) || (code in 0xE000..0xFFFD) ||
            (code in 0x10000..0x10FFFF)
}
