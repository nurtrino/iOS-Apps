import Foundation

/// Named HTML character references.
///
/// This table exists twice over: once to render text, and once to *repair XML*.
/// The second use is the reason it has to be here rather than leaning on
/// `NSAttributedString`'s HTML importer. `&nbsp;` and friends are HTML
/// entities, not XML ones, and an RSS feed that puts one inside a
/// `<description>` — nearly all of them do — is not well-formed XML.
/// `XMLParser` stops dead at the first one with "undefined entity" and the
/// whole feed comes back empty. Rewriting them to numeric references before
/// parsing is what makes real-world feeds parse at all.
enum HTMLEntities {

    static let table: [String: String] = [
        "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
        "apos": "'", "cent": "¢", "pound": "£", "yen": "¥", "euro": "€",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
        "middot": "·", "bull": "•", "hellip": "…", "prime": "′", "Prime": "″",
        "ndash": "–", "mdash": "—", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "sbquo": "‚", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "„",
        "dagger": "†", "Dagger": "‡", "permil": "‰", "lsaquo": "‹",
        "rsaquo": "›", "laquo": "«", "raquo": "»", "deg": "°", "plusmn": "±",
        "frac14": "¼", "frac12": "½", "frac34": "¾", "times": "×",
        "divide": "÷", "minus": "−", "ne": "≠", "le": "≤", "ge": "≥",
        "asymp": "≈", "infin": "∞", "sup2": "²", "sup3": "³", "micro": "µ",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",
        "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦",
        "star": "☆", "check": "✓", "cross": "✗", "shy": "\u{00AD}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}",
        "rlm": "\u{200F}", "iexcl": "¡", "iquest": "¿", "curren": "¤",
        "brvbar": "¦", "uml": "¨", "ordf": "ª", "not": "¬", "macr": "¯",
        "acute": "´", "cedil": "¸", "ordm": "º", "sup1": "¹", "szlig": "ß",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã",
        "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
        "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
        "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô",
        "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù",
        "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý",
        "yuml": "ÿ", "Agrave": "À", "Aacute": "Á", "Acirc": "Â",
        "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê",
        "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î",
        "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
        "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
        "Yacute": "Ý", "THORN": "Þ", "thorn": "þ", "eth": "ð", "ETH": "Ð",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ",
        "tau": "τ", "phi": "φ", "omega": "ω", "Omega": "Ω", "Delta": "Δ",
        "Sigma": "Σ", "Pi": "Π",
    ]

    /// The five references XML defines itself. Everything else has to be
    /// rewritten before `XMLParser` sees it.
    static let xmlBuiltIns: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    static func replacement(for name: String) -> String? {
        if let direct = table[name] { return direct }

        // Numeric, decimal or hex.
        guard name.hasPrefix("#") else { return nil }
        let digits = String(name.dropFirst())
        let scalarValue: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            scalarValue = UInt32(digits.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(digits, radix: 10)
        }
        guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}

/// Turning markup into text, and finding the picture in it.
enum HTMLText {

    /// Tags whose *content* is not text at all. Dropped wholesale rather than
    /// stripped, or a feed item ends up with a stylesheet in its dek.
    private static let opaqueTags = ["script", "style", "noscript", "iframe", "svg"]

    /// Tags that end a line of text.
    private static let breaking: Set<String> = [
        "br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "section", "article", "figure", "figcaption", "ul",
        "ol", "table", "hr", "pre",
    ]

    /// Markup in, readable plain text out.
    ///
    /// Note the newline flattening before tags are stripped. Newlines in source
    /// markup are insignificant whitespace — exactly the same as a space — and
    /// only tags create real line breaks. Skip this and every publisher who
    /// wraps their HTML at eighty columns gets a line break in the middle of
    /// each sentence, which in a two-line dek means seeing half as many words.
    ///
    /// This is for summaries and search text. The reader uses `HTMLDocument`,
    /// which keeps `<pre>` whitespace intact; here it is deliberately lost.
    static func plainText(from html: String) -> String {
        var text = removeOpaqueSections(from: html)
        text = text.replacingOccurrences(of: "\r\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = stripTags(from: text, breakingProduceNewlines: true)
        text = decodeEntities(in: text)
        return collapseWhitespace(in: text)
    }

    static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }

            // An entity is short. Scanning further than this and finding a ';'
            // means it was a bare ampersand and a semicolon much later in the
            // sentence, not a reference.
            let limit = text.index(index, offsetBy: 34, limitedBy: text.endIndex) ?? text.endIndex
            let searchRange = text.index(after: index)..<limit
            guard let semicolon = text[searchRange].firstIndex(of: ";") else {
                out.append(character)
                index = text.index(after: index)
                continue
            }

            let name = String(text[text.index(after: index)..<semicolon])
            if !name.isEmpty, let replacement = HTMLEntities.replacement(for: name) {
                out.append(replacement)
                index = text.index(after: semicolon)
            } else {
                out.append(character)
                index = text.index(after: index)
            }
        }
        return out
    }

    static func removeOpaqueSections(from html: String) -> String {
        var text = html
        for tag in opaqueTags {
            text = removeSections(in: text, tag: tag)
        }
        // Comments, including the conditional ones that wrap real markup.
        text = removeDelimited(in: text, open: "<!--", close: "-->")
        return text
    }

    private static func removeSections(in html: String, tag: String) -> String {
        var out = ""
        var remainder = Substring(html)

        while let open = remainder.range(of: "<\(tag)", options: .caseInsensitive) {
            // "<sect" must not match "<section": the next character has to end
            // the tag name.
            let after = open.upperBound
            let isWholeTag = after == remainder.endIndex
                || !(remainder[after].isLetter || remainder[after].isNumber)
            guard isWholeTag else {
                out += remainder[remainder.startIndex..<after]
                remainder = remainder[after...]
                continue
            }

            out += remainder[remainder.startIndex..<open.lowerBound]
            let rest = remainder[after...]
            if let close = rest.range(of: "</\(tag)", options: .caseInsensitive),
               let end = rest[close.upperBound...].firstIndex(of: ">") {
                remainder = rest[rest.index(after: end)...]
            } else {
                // Unterminated: everything from here on was inside it.
                remainder = rest[rest.endIndex...]
            }
        }
        out += remainder
        return out
    }

    private static func removeDelimited(in html: String, open: String, close: String) -> String {
        var out = ""
        var remainder = Substring(html)
        while let start = remainder.range(of: open) {
            out += remainder[remainder.startIndex..<start.lowerBound]
            guard let end = remainder[start.upperBound...].range(of: close) else {
                return out
            }
            remainder = remainder[end.upperBound...]
        }
        out += remainder
        return out
    }

    static func stripTags(from html: String, breakingProduceNewlines: Bool) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                out.append(html[index])
                index = html.index(after: index)
                continue
            }

            guard let close = html[index...].firstIndex(of: ">") else {
                // A stray '<' in prose. Keep it — dropping the rest of the
                // document because someone wrote "5 < 6" is worse.
                out.append(html[index])
                index = html.index(after: index)
                continue
            }

            let tag = html[html.index(after: index)..<close]
            if breakingProduceNewlines {
                let name = tagName(in: tag)
                if breaking.contains(name) {
                    out.append("\n")
                    if name == "li" && !tag.hasPrefix("/") { out.append("• ") }
                }
            }
            index = html.index(after: close)
        }
        return out
    }

    /// The lowercased element name inside a tag body, without its slash.
    static func tagName(in tagBody: Substring) -> String {
        var name = ""
        for character in tagBody {
            if character == "/" && name.isEmpty { continue }
            if character.isLetter || character.isNumber { name.append(character) } else { break }
        }
        return name.lowercased()
    }

    static func collapseWhitespace(in text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)

        var pendingNewlines = 0
        var pendingSpace = false
        var wroteAnything = false

        for character in text {
            if character == "\n" || character == "\r" {
                pendingNewlines += 1
                pendingSpace = false
                continue
            }
            if character == " " || character == "\t" || character == "\u{00A0}" {
                pendingSpace = true
                continue
            }

            if wroteAnything {
                if pendingNewlines > 0 {
                    // One, always. `</p><p>` emits two breaks for what is a
                    // single paragraph boundary, and `<li>` inside `<ul>`
                    // emits three — so counting them faithfully produces a
                    // summary full of blank lines. Real paragraph structure is
                    // the reader's job, and `HTMLDocument` models it properly.
                    out.append("\n")
                } else if pendingSpace {
                    out.append(" ")
                }
            }
            pendingNewlines = 0
            pendingSpace = false
            out.append(character)
            wroteAnything = true
        }
        return out
    }

    /// The first real image in a block of markup.
    ///
    /// Lazy-loading is why this checks more than `src`: most WordPress themes
    /// put a placeholder in `src` and the real file in `data-src`, so reading
    /// `src` alone gets you a grey 1x1 for every article.
    static func firstImageURL(in html: String, relativeTo base: URL? = nil) -> URL? {
        var remainder = Substring(html)

        while let open = remainder.range(of: "<img", options: .caseInsensitive) {
            guard let close = remainder[open.upperBound...].firstIndex(of: ">") else { return nil }
            let tag = remainder[open.upperBound..<close]

            for attribute in ["data-original", "data-lazy-src", "data-src", "src"] {
                guard let value = attributeValue(attribute, in: tag), !value.isEmpty else { continue }
                guard !value.hasPrefix("data:") else { continue }
                guard let url = URL(string: value, relativeTo: base)?.absoluteURL else { continue }
                if isLikelyTrackingPixel(url) { continue }
                return url
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return nil
    }

    /// An attribute value from a tag body. Handles double quotes, single
    /// quotes and the unquoted form.
    static func attributeValue(_ name: String, in tagBody: Substring) -> String? {
        var remainder = tagBody

        while let found = remainder.range(of: name, options: .caseInsensitive) {
            // Must be a whole attribute name: "src" must not match "data-src",
            // and the next non-space character must be '='.
            let precededProperly = found.lowerBound == remainder.startIndex
                || !(remainder[remainder.index(before: found.lowerBound)].isLetter
                     || remainder[remainder.index(before: found.lowerBound)] == "-")

            var cursor = found.upperBound
            while cursor < remainder.endIndex && remainder[cursor] == " " {
                cursor = remainder.index(after: cursor)
            }
            guard precededProperly, cursor < remainder.endIndex, remainder[cursor] == "=" else {
                remainder = remainder[found.upperBound...]
                continue
            }

            cursor = remainder.index(after: cursor)
            while cursor < remainder.endIndex && remainder[cursor] == " " {
                cursor = remainder.index(after: cursor)
            }
            guard cursor < remainder.endIndex else { return nil }

            let quote = remainder[cursor]
            if quote == "\"" || quote == "'" {
                let valueStart = remainder.index(after: cursor)
                guard let valueEnd = remainder[valueStart...].firstIndex(of: quote) else { return nil }
                return decodeEntities(in: String(remainder[valueStart..<valueEnd]))
            }
            let valueEnd = remainder[cursor...].firstIndex(where: { $0 == " " || $0 == ">" })
                ?? remainder.endIndex
            return decodeEntities(in: String(remainder[cursor..<valueEnd]))
        }
        return nil
    }

    /// Analytics beacons and spacer GIFs, which are worse than no image.
    private static func isLikelyTrackingPixel(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.hasSuffix(".gif") && (path.contains("pixel") || path.contains("spacer")) {
            return true
        }
        let host = url.host?.lowercased() ?? ""
        return host.contains("feedburner") || host.contains("doubleclick")
            || host.contains("googleadservices") || host.contains("scorecardresearch")
            || path.contains("/1x1") || path.contains("blank.gif")
    }
}
