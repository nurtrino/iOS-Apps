import Foundation

/// The output of parsing a comment body.
///
/// Blocks rather than one attributed string: a code block scrolls horizontally
/// on its own, independently of the paragraphs around it, and a single
/// attributed string cannot express that.
enum CommentBlock: Hashable {
    case paragraph(CommentParagraph)
    case code(String)
}

struct CommentParagraph: Hashable {
    let text: String
    let spans: [CommentSpan]
}

/// A styled range, in **character offsets** into the paragraph's text.
///
/// Offsets are grapheme-cluster counts, matching how Swift measures `String`.
/// They are computed and consumed entirely within this platform, so they never
/// have to agree with the Kotlin port's UTF-16 offsets.
struct CommentSpan: Hashable {
    let start: Int
    let length: Int
    let style: CommentStyle

    var end: Int { start + length }
}

enum CommentStyle: Hashable {
    case italic
    case bold
    case underline
    /// 4chan's `<s>`: rendered blacked-out until tapped.
    case spoiler
    /// `<span class="quote">`, the `>greentext` convention.
    case greentext
    /// A quoted post that no longer exists.
    case deadlink
    case inlineCode
    /// Shift-JIS art, which only lines up in a monospaced font.
    case shiftJIS
    /// Kept as the raw string rather than a `URL` so the original spelling
    /// survives; `url` does the conversion at render time.
    case link(String)
    /// A `>>123` reference. `board` and `thread` are nil when the target is in
    /// the thread being read, which is the overwhelmingly common case.
    case quotelink(board: String?, thread: Int?, post: Int)
    /// A `>>>/g/` reference to a board rather than a post.
    case boardLink(String)

    var url: URL? {
        if case .link(let raw) = self { return URL(string: raw) }
        return nil
    }
}

/// The 4chan comment parser.
///
/// Deliberately free of any UI import: this file is shared, in spirit and
/// almost line for line, with the Kotlin port, and it is the piece most worth
/// testing in isolation. The reference implementation and its assertions live
/// in `tools/comment_parser_reference.py` and `tools/test_parser.py` — change
/// one, change both.
///
/// 4chan's `com` field is a small, fixed HTML subset:
///
///     <br>                                    line break
///     <span class="quote">&gt;text</span>     greentext
///     <a href="#p123" class="quotelink">      reply link within the thread
///     <a href="/pol/thread/1#p2" ...>         cross-thread link
///     <a href="//boards.4chan.org/g/" ...>    cross-board link
///     <span class="deadlink">                 quoted post that is gone
///     <s>text</s>                             spoiler
///     <pre class="prettyprint">               code block
///     <span class="sjis">                     Shift-JIS art
///     <wbr>                                   word-break hint
///     <b> <strong> <i> <em> <u>               emphasis
///     &gt; &lt; &amp; &#039; &#x27;            entities
enum CommentMarkup {

    // MARK: - Entities

    private static let namedEntities: [String: Character] = [
        "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'",
        "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "deg": "°", "middot": "·", "bull": "•",
        "trade": "™", "copy": "©", "reg": "®",
        "eacute": "é", "egrave": "è", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ccedil": "ç", "ntilde": "ñ", "pound": "£",
        "euro": "€", "yen": "¥", "sect": "§", "para": "¶",
        "times": "×", "divide": "÷", "plusmn": "±",
        "frac12": "½", "frac14": "¼", "sup2": "²", "sup3": "³",
    ]

    /// A bare `&` in prose is common. Without a bound on the lookahead, the
    /// scan for the closing `;` swallows the rest of the line.
    private static let maxEntityLength = 12

    /// Decode the entity starting at `chars[i] == "&"`.
    /// Returns nil when this is not an entity, in which case the caller emits a
    /// literal `&`.
    private static func decodeEntity(_ chars: [Character], _ i: Int) -> (Character, Int)? {
        let limit = min(chars.count, i + maxEntityLength + 2)
        var semi = -1
        var j = i + 1
        while j < limit {
            let c = chars[j]
            if c == ";" { semi = j; break }
            // Entities are alphanumeric, plus a leading '#'. Anything else
            // means this '&' was just an ampersand.
            if !(c.isLetter || c.isNumber || (c == "#" && j == i + 1)) { return nil }
            j += 1
        }
        guard semi > i + 1 else { return nil }

        let body = String(chars[(i + 1)..<semi])
        if body.hasPrefix("#") {
            let digits = String(body.dropFirst())
            var code: UInt32?
            if digits.lowercased().hasPrefix("x") {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits, radix: 10)
            }
            guard let value = code,
                  value > 0, value <= 0x10FFFF,
                  !(0xD800...0xDFFF).contains(value),
                  let scalar = Unicode.Scalar(value)
            else { return nil }
            return (Character(scalar), semi + 1)
        }

        guard let mapped = namedEntities[body] else { return nil }
        return (mapped, semi + 1)
    }

    /// Decode every entity in a plain string. Used for `href` attributes, which
    /// arrive escaped just like the body text.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "&", let (decoded, next) = decodeEntity(chars, i) {
                out.append(decoded)
                i = next
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    // MARK: - Tag scanning

    private struct Tag {
        let name: String
        let attributes: [String: String]
        let isClosing: Bool
        let endIndex: Int
    }

    /// Parse the tag starting at `chars[i] == "<"`, or return nil when this `<`
    /// is not the start of a tag and must be treated as literal text.
    ///
    /// The guard on the character after `<` is what stops `a < b and c > d`
    /// from being read as a tag and swallowing everything up to the `>`.
    private static func parseTag(_ chars: [Character], _ i: Int) -> Tag? {
        let n = chars.count
        guard i + 1 < n else { return nil }
        let isClosing = chars[i + 1] == "/"
        if isClosing {
            guard i + 2 < n, chars[i + 2].isLetter else { return nil }
        } else {
            guard chars[i + 1].isLetter else { return nil }
        }

        var j = isClosing ? i + 2 : i + 1
        let nameStart = j
        while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" {
            j += 1
        }
        let name = String(chars[nameStart..<j]).lowercased()
        guard !name.isEmpty else { return nil }

        var attributes: [String: String] = [:]
        while j < n {
            while j < n, chars[j].isWhitespace { j += 1 }
            guard j < n else { return nil }
            if chars[j] == ">" {
                return Tag(name: name, attributes: attributes, isClosing: isClosing, endIndex: j + 1)
            }
            if chars[j] == "/" { j += 1; continue }

            let attrStart = j
            while j < n, !chars[j].isWhitespace, chars[j] != "=", chars[j] != ">" { j += 1 }
            let attrName = String(chars[attrStart..<j]).lowercased()
            while j < n, chars[j].isWhitespace { j += 1 }

            var value = ""
            if j < n, chars[j] == "=" {
                j += 1
                while j < n, chars[j].isWhitespace { j += 1 }
                if j < n, chars[j] == "\"" || chars[j] == "'" {
                    let quote = chars[j]
                    j += 1
                    let valueStart = j
                    while j < n, chars[j] != quote { j += 1 }
                    value = String(chars[valueStart..<j])
                    j += 1
                } else {
                    let valueStart = j
                    while j < n, !chars[j].isWhitespace, chars[j] != ">" { j += 1 }
                    value = String(chars[valueStart..<j])
                }
            }
            if !attrName.isEmpty { attributes[attrName] = value }
        }
        // Ran off the end without a '>': not a tag.
        return nil
    }

    // MARK: - Link classification

    private static let safeSchemes = ["http://", "https://"]
    private static let boardHosts = ["boards.4chan.org", "boards.4channel.org"]

    /// Turn an `<a>` into a style, or nil if the link should be dropped while
    /// keeping its text.
    ///
    /// Quotelinks are recognised by shape *before* any scheme check, because
    /// their hrefs are relative (`#p123`, `/pol/thread/1#p2`) and would
    /// otherwise fail an http(s) allowlist. That allowlist exists because a
    /// comment body is entirely untrusted input, and `javascript:` must never
    /// become a tappable link.
    static func classifyHref(_ rawHref: String?, classes: [String]) -> CommentStyle? {
        let href = decodeEntities(rawHref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty else { return nil }

        let isQuotelink = classes.contains("quotelink")

        // #p123456789 — same thread.
        if href.hasPrefix("#p") {
            let digits = String(href.dropFirst(2))
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let post = Int(digits) {
                return .quotelink(board: nil, thread: nil, post: post)
            }
            return nil
        }

        var path = href
        var host: String?

        if path.hasPrefix("//") {
            let rest = String(path.dropFirst(2))
            if let slash = rest.firstIndex(of: "/") {
                host = String(rest[rest.startIndex..<slash])
                path = String(rest[slash...])
            } else {
                host = rest
                path = "/"
            }
        } else {
            for scheme in safeSchemes where href.lowercased().hasPrefix(scheme) {
                let rest = String(path.dropFirst(scheme.count))
                let candidateHost: String
                let candidatePath: String
                if let slash = rest.firstIndex(of: "/") {
                    candidateHost = String(rest[rest.startIndex..<slash])
                    candidatePath = String(rest[slash...])
                } else {
                    candidateHost = rest
                    candidatePath = "/"
                }
                if boardHosts.contains(candidateHost) {
                    host = candidateHost
                    path = candidatePath
                }
                break
            }
        }

        if host == nil && !path.hasPrefix("/") {
            // An ordinary absolute URL to somewhere else.
            let low = href.lowercased()
            return safeSchemes.contains(where: { low.hasPrefix($0) }) ? .link(href) : nil
        }

        if let host, !boardHosts.contains(host) {
            let low = href.lowercased()
            return safeSchemes.contains(where: { low.hasPrefix($0) }) ? .link(href) : nil
        }

        // Board-relative: /board/, /board/thread/123, /board/thread/123#p456
        let parts = path.split(separator: "/").map(String.init)
        guard let board = parts.first else { return nil }
        if parts.count == 1 { return .boardLink(board) }

        if parts.count >= 3, parts[1] == "thread" {
            var tail = parts[2]
            var anchor: String?
            if let hashRange = tail.range(of: "#p") {
                anchor = String(tail[hashRange.upperBound...])
                tail = String(tail[tail.startIndex..<hashRange.lowerBound])
            }
            guard !tail.isEmpty, tail.allSatisfy({ $0.isNumber }), let threadNo = Int(tail) else {
                return nil
            }
            let postNo: Int
            if let anchor, !anchor.isEmpty, anchor.allSatisfy({ $0.isNumber }), let parsed = Int(anchor) {
                postNo = parsed
            } else {
                postNo = threadNo
            }
            return .quotelink(board: board, thread: threadNo, post: postNo)
        }

        if isQuotelink { return .boardLink(board) }
        let low = href.lowercased()
        return safeSchemes.contains(where: { low.hasPrefix($0) }) ? .link(href) : nil
    }

    private static func classifySpan(_ classes: [String]) -> CommentStyle? {
        if classes.contains("quote") { return .greentext }
        if classes.contains("deadlink") { return .deadlink }
        if classes.contains("sjis") { return .shiftJIS }
        return nil
    }

    // MARK: - Parsing

    private static let emphasis: [String: CommentStyle] = [
        "b": .bold, "strong": .bold,
        "i": .italic, "em": .italic,
        "u": .underline,
        "s": .spoiler, "strike": .spoiler, "del": .spoiler,
        "code": .inlineCode,
    ]

    /// A closing tag pops the innermost element opened by the *same group*, not
    /// the innermost element with a matching style. Matching on style cannot
    /// work: an element may carry no style at all (an unknown `<span>`, or an
    /// `<a>` whose href was rejected), and those still have to be popped by
    /// their closing tag or they leak up the stack and corrupt every range that
    /// follows.
    private static let closeGroup: [String: String] = [
        "strong": "b", "em": "i", "strike": "s", "del": "s",
    ]

    private static func group(for tagName: String) -> String {
        closeGroup[tagName] ?? tagName
    }

    private static let blockBreaking: Set<String> = ["p", "div"]

    /// An element currently open on the stack. `style` is nil for elements that
    /// contribute no styling but still need popping.
    private struct OpenElement {
        let group: String
        let style: CommentStyle?
        var start: Int
    }

    static func parse(_ html: String?) -> [CommentBlock] {
        guard let html, !html.isEmpty else { return [] }

        let chars = Array(html)
        let n = chars.count

        var blocks: [CommentBlock] = []
        var text: [Character] = []
        var spans: [CommentSpan] = []
        var open: [OpenElement] = []

        // Trim surrounding whitespace and shift the spans to match, or every
        // range drifts by the number of leading spaces removed.
        func emit(_ raw: [Character], _ rawSpans: [CommentSpan]) {
            var lead = 0
            while lead < raw.count, raw[lead].isWhitespace { lead += 1 }
            var trail = raw.count
            while trail > lead, raw[trail - 1].isWhitespace { trail -= 1 }
            guard trail > lead else { return }  // whitespace-only paragraph

            let trimmed = Array(raw[lead..<trail])
            var shifted: [CommentSpan] = []
            shifted.reserveCapacity(rawSpans.count)
            for span in rawSpans {
                let start = max(0, span.start - lead)
                let end = min(trimmed.count, span.end - lead)
                if end > start {
                    shifted.append(CommentSpan(start: start, length: end - start, style: span.style))
                }
            }
            shifted.sort { ($0.start, $0.length) < ($1.start, $1.length) }
            blocks.append(.paragraph(CommentParagraph(text: String(trimmed), spans: shifted)))
        }

        // Close every open style at the end of the line, then reopen it at the
        // start of the next one, so emphasis survives a <br> without producing
        // a span that runs past the end of its own paragraph.
        func flushParagraph() {
            let length = text.count
            for element in open {
                if let style = element.style, length > element.start {
                    spans.append(CommentSpan(start: element.start,
                                             length: length - element.start,
                                             style: style))
                }
            }
            emit(text, spans)
            text.removeAll(keepingCapacity: true)
            spans.removeAll(keepingCapacity: true)
            for index in open.indices { open[index].start = 0 }
        }

        func closeGroupNamed(_ name: String) {
            for index in stride(from: open.count - 1, through: 0, by: -1) where open[index].group == name {
                let element = open[index]
                let length = text.count - element.start
                if let style = element.style, length > 0 {
                    spans.append(CommentSpan(start: element.start, length: length, style: style))
                }
                open.remove(at: index)
                return
            }
        }

        var i = 0
        while i < n {
            let c = chars[i]

            if c == "<" {
                guard let tag = parseTag(chars, i) else {
                    text.append("<")  // stray '<' in prose
                    i += 1
                    continue
                }
                i = tag.endIndex

                switch tag.name {
                case "wbr":
                    // A word-break hint. It must vanish leaving nothing behind:
                    // 4chan injects it into long URLs and filenames, and
                    // inserting any character here corrupts them.
                    continue

                case "br":
                    flushParagraph()
                    continue

                case "pre":
                    if !tag.isClosing {
                        flushParagraph()
                        let (codeText, next) = readCodeBlock(chars, i)
                        i = next
                        if codeText.contains(where: { !$0.isWhitespace }) {
                            blocks.append(.code(codeText))
                        }
                    }
                    continue

                case "a":
                    if tag.isClosing {
                        closeGroupNamed("a")
                    } else {
                        let classes = (tag.attributes["class"] ?? "").lowercased()
                            .split(separator: " ").map(String.init)
                        // A rejected href opens with no style: the anchor text
                        // still belongs in the output, only the link goes away.
                        open.append(OpenElement(group: "a",
                                                style: classifyHref(tag.attributes["href"], classes: classes),
                                                start: text.count))
                    }
                    continue

                case "span":
                    if tag.isClosing {
                        closeGroupNamed("span")
                    } else {
                        let classes = (tag.attributes["class"] ?? "").lowercased()
                            .split(separator: " ").map(String.init)
                        open.append(OpenElement(group: "span",
                                                style: classifySpan(classes),
                                                start: text.count))
                    }
                    continue

                default:
                    if blockBreaking.contains(tag.name) {
                        flushParagraph()
                        continue
                    }
                    if let style = emphasis[tag.name] {
                        if tag.isClosing {
                            closeGroupNamed(group(for: tag.name))
                        } else {
                            open.append(OpenElement(group: group(for: tag.name),
                                                    style: style,
                                                    start: text.count))
                        }
                        continue
                    }
                    // Unknown tag: drop the tag, keep the text inside it.
                    continue
                }
            }

            if c == "&" {
                if let (decoded, next) = decodeEntity(chars, i) {
                    text.append(decoded)
                    i = next
                    continue
                }
                text.append("&")
                i += 1
                continue
            }

            if c == "\r" { i += 1; continue }
            if c == "\n" { flushParagraph(); i += 1; continue }

            text.append(c)
            i += 1
        }

        // Close whatever is still open at the end of the body.
        let length = text.count
        for element in open {
            if let style = element.style, length > element.start {
                spans.append(CommentSpan(start: element.start,
                                         length: length - element.start,
                                         style: style))
            }
        }
        emit(text, spans)

        return blocks
    }

    /// Consume up to and including the matching `</pre>`.
    private static func readCodeBlock(_ chars: [Character], _ start: Int) -> (String, Int) {
        var out: [Character] = []
        var i = start
        let n = chars.count
        while i < n {
            if chars[i] == "<" {
                if let tag = parseTag(chars, i) {
                    if tag.name == "pre", tag.isClosing {
                        return (String(out), tag.endIndex)
                    }
                    if tag.name == "br" { out.append("\n") }
                    // Any other markup inside a code block is dropped, its text kept.
                    i = tag.endIndex
                    continue
                }
                out.append("<")
                i += 1
                continue
            }
            if chars[i] == "&", let (decoded, next) = decodeEntity(chars, i) {
                out.append(decoded)
                i = next
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return (String(out), i)
    }

    // MARK: - Quotelink extraction

    /// Every post number this comment quotes, in order, without duplicates.
    ///
    /// Runs the full parser rather than a regex over `>>\d+`, so that a `>>123`
    /// inside a code block, or inside a link that was rejected, does not
    /// register as a reply and pollute the backlink index.
    static func quotedPostNumbers(in html: String?) -> [Int] {
        var seen: [Int] = []
        for block in parse(html) {
            guard case .paragraph(let paragraph) = block else { continue }
            for span in paragraph.spans {
                if case .quotelink(let board, _, let post) = span.style,
                   board == nil,
                   !seen.contains(post) {
                    seen.append(post)
                }
            }
        }
        return seen
    }

    /// True when any paragraph carries a spoiler span.
    ///
    /// The renderer uses this to decide whether a tap-to-reveal gesture belongs
    /// on a comment *at all*. Attaching one unconditionally swallows the taps
    /// meant for the links inside the text, which is most of what a reader taps.
    static func containsSpoiler(_ blocks: [CommentBlock]) -> Bool {
        for block in blocks {
            guard case .paragraph(let paragraph) = block else { continue }
            if paragraph.spans.contains(where: { $0.style == .spoiler }) { return true }
        }
        return false
    }

    /// True when this paragraph is nothing but quotelinks aimed at `targets`.
    ///
    /// Used by the threaded view. 4chan posts open with `>>123` naming the post
    /// being answered, because on a flat board that line *is* the addressing
    /// mechanism. Once a reply is drawn underneath the post it answers, the
    /// line is pure noise — Reddit and HN don't print "re: parent" above every
    /// comment.
    ///
    /// Only whole-line quotes at an ancestor qualify: `>>123 you're wrong`
    /// carries real text and stays, and a quote aimed at some *other* post is
    /// information the nesting does not convey, so it stays too.
    static func isQuoteOnlyParagraph(_ paragraph: CommentParagraph,
                                     targeting targets: Set<Int>) -> Bool {
        let characters = Array(paragraph.text)
        var covered = [Bool](repeating: false, count: characters.count)
        var hitTarget = false

        for span in paragraph.spans {
            guard case .quotelink(let board, _, let post) = span.style else { continue }
            // Every quotelink on the line must point at an ancestor. A line
            // that also names some *other* post is carrying information the
            // nesting cannot show — a reply sits under one parent — so it stays
            // whole.
            guard board == nil, targets.contains(post) else { return false }
            hitTarget = true
            var index = max(0, span.start)
            let upper = min(characters.count, span.end)
            while index < upper {
                covered[index] = true
                index += 1
            }
        }

        guard hitTarget else { return false }
        for (index, character) in characters.enumerated() {
            if !character.isWhitespace && !covered[index] { return false }
        }
        return true
    }
}

/// Parsed-comment cache.
///
/// Threads re-render constantly while scrolling and collapsing, and re-parsing
/// on every pass is the difference between smooth and stuttery. Keyed on the
/// raw HTML so identical bodies share an entry.
final class CommentParserCache {
    static let shared = CommentParserCache()

    private final class Box {
        let blocks: [CommentBlock]
        init(_ blocks: [CommentBlock]) { self.blocks = blocks }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 3000
        return cache
    }()

    private init() {}

    func blocks(for html: String?) -> [CommentBlock] {
        guard let html, !html.isEmpty else { return [] }
        let key = html as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let parsed = CommentMarkup.parse(html)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    func clear() {
        cache.removeAllObjects()
    }
}
