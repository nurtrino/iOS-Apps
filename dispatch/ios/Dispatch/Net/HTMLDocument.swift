import Foundation

/// One laid-out piece of an article.
///
/// The id is the block's position. Two identical paragraphs in one article are
/// still different blocks, and SwiftUI needs to tell them apart to animate and
/// recycle rows correctly — so identity is positional rather than derived from
/// the content.
struct ArticleBlock: Identifiable {

    enum Kind {
        case paragraph(AttributedString)
        case heading(AttributedString, level: Int)
        case quote(AttributedString)
        case bullet(AttributedString, marker: String)
        case image(URL)
        case code(String)
        case rule
    }

    let id: Int
    let kind: Kind
}

/// Turns an article body into blocks a SwiftUI view can lay out.
///
/// The alternative — `NSAttributedString(data:options:[.documentType: .html])`
/// — is tempting and wrong for this. It is a full WebKit parse: it must run on
/// the main thread, takes tens of milliseconds per article, and returns one
/// enormous attributed string in which images are inline text attachments that
/// cannot be resized to the screen. Scrolling a feed of them janks visibly.
///
/// Parsing to blocks instead means images become real SwiftUI views that load
/// lazily and size properly, headings can use dynamic type, and pull quotes can
/// be styled. The parse is also cheap enough to run off the main thread while
/// the screen is still animating in.
enum HTMLDocument {

    /// Tags that end the current run of text.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
        "li", "ul", "ol", "hr", "pre", "figure", "figcaption", "section",
        "article", "table", "tr", "td", "th", "header", "footer", "aside",
    ]

    static func parse(_ html: String, baseURL: URL? = nil) -> [ArticleBlock] {
        var parser = Parser(html: HTMLText.removeOpaqueSections(from: html), baseURL: baseURL)
        return parser.parse()
    }

    private struct Parser {

        let html: String
        let baseURL: URL?

        private var kinds: [ArticleBlock.Kind] = []
        private var run = AttributedString()

        /// Inline state, as counters and a stack so nesting unwinds correctly.
        private var bold = 0
        private var italic = 0
        private var links: [URL?] = []

        /// Block state.
        private var headingLevel = 0
        private var quoteDepth = 0
        private var preDepth = 0
        private var listStack: [(ordered: Bool, counter: Int)] = []
        private var inListItem = false

        init(html: String, baseURL: URL?) {
            self.html = html
            self.baseURL = baseURL
        }

        mutating func parse() -> [ArticleBlock] {
            var index = html.startIndex

            while index < html.endIndex {
                guard html[index] == "<" else {
                    // Everything up to the next tag is text.
                    let nextTag = html[index...].firstIndex(of: "<") ?? html.endIndex
                    appendText(String(html[index..<nextTag]))
                    index = nextTag
                    continue
                }

                guard let close = html[index...].firstIndex(of: ">") else {
                    // A stray '<' in prose. Keep the rest as text rather than
                    // discarding the tail of the article.
                    appendText(String(html[index...]))
                    break
                }

                handleTag(html[html.index(after: index)..<close])
                index = html.index(after: close)
            }

            flush()
            return kinds.enumerated().map { ArticleBlock(id: $0.offset, kind: $0.element) }
        }

        // MARK: - Tags

        private mutating func handleTag(_ body: Substring) {
            let isClosing = body.hasPrefix("/")
            let name = HTMLText.tagName(in: body)
            guard !name.isEmpty else { return }

            if HTMLDocument.blockTags.contains(name) {
                handleBlockTag(name, isClosing: isClosing)
                return
            }

            switch name {
            case "img":
                guard !isClosing else { return }
                flush()
                if let url = imageURL(in: body) { kinds.append(.image(url)) }

            case "a":
                if isClosing {
                    if !links.isEmpty { links.removeLast() }
                } else if let href = HTMLText.attributeValue("href", in: body) {
                    links.append(URL(string: href, relativeTo: baseURL)?.absoluteURL)
                } else {
                    // Push nil anyway, so the matching `</a>` pops this rather
                    // than a real link further up the stack.
                    links.append(nil)
                }

            case "b", "strong":
                bold = max(0, bold + (isClosing ? -1 : 1))
            case "i", "em", "cite":
                italic = max(0, italic + (isClosing ? -1 : 1))
            default:
                break
            }
        }

        private mutating func handleBlockTag(_ name: String, isClosing: Bool) {
            switch name {
            case "br":
                // A line break inside a paragraph, not a paragraph boundary.
                run.append(AttributedString("\n"))

            case "hr":
                flush()
                kinds.append(.rule)

            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                headingLevel = isClosing ? 0 : (Int(name.dropFirst()) ?? 2)

            case "blockquote":
                flush()
                quoteDepth = max(0, quoteDepth + (isClosing ? -1 : 1))

            case "pre":
                flush()
                preDepth = max(0, preDepth + (isClosing ? -1 : 1))

            case "ul", "ol":
                flush()
                if isClosing {
                    if !listStack.isEmpty { listStack.removeLast() }
                } else {
                    listStack.append((ordered: name == "ol", counter: 0))
                }

            case "li":
                flush()
                inListItem = !isClosing
                if !isClosing, !listStack.isEmpty { listStack[listStack.count - 1].counter += 1 }

            default:
                flush()
            }
        }

        private func imageURL(in body: Substring) -> URL? {
            for attribute in ["data-original", "data-lazy-src", "data-src", "src"] {
                guard let value = HTMLText.attributeValue(attribute, in: body),
                      !value.isEmpty, !value.hasPrefix("data:") else { continue }
                if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL { return url }
            }
            return nil
        }

        // MARK: - Text

        private mutating func appendText(_ raw: String) {
            guard !raw.isEmpty else { return }
            let decoded = HTMLText.decodeEntities(in: raw)

            // Whitespace between tags is layout, not content — except inside
            // <pre>, where it is the entire point.
            let text = preDepth > 0 ? decoded : collapseInline(decoded)
            guard !text.isEmpty else { return }
            // Never open a paragraph with the space that separated two tags.
            if run.characters.isEmpty && text == " " { return }

            var piece = AttributedString(text)

            if bold > 0 && italic > 0 {
                piece.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
            } else if bold > 0 {
                piece.inlinePresentationIntent = .stronglyEmphasized
            } else if italic > 0 {
                piece.inlinePresentationIntent = .emphasized
            }

            if let link = links.last, let url = link {
                piece.link = url
            }
            run.append(piece)
        }

        /// Newlines and runs of spaces in source markup collapse to one space.
        private func collapseInline(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.count)
            var pendingSpace = false

            for character in text {
                if character.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(character)
            }
            if pendingSpace { out.append(" ") }
            return out
        }

        // MARK: - Flush

        private mutating func flush() {
            defer { run = AttributedString() }

            guard !String(run.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            if preDepth > 0 {
                kinds.append(.code(String(run.characters)))
                return
            }

            // Trim the attributed string rather than the plain one, so styling
            // survives. Leading and trailing whitespace comes from the markup's
            // indentation and is never intentional.
            let trimmed = trimming(run)

            if headingLevel > 0 {
                kinds.append(.heading(trimmed, level: headingLevel))
            } else if inListItem, let list = listStack.last {
                kinds.append(.bullet(trimmed, marker: list.ordered ? "\(list.counter)." : "•"))
            } else if quoteDepth > 0 {
                kinds.append(.quote(trimmed))
            } else {
                kinds.append(.paragraph(trimmed))
            }
        }

        private func trimming(_ value: AttributedString) -> AttributedString {
            var result = value
            while let first = result.characters.first, first.isWhitespace {
                result.removeSubrange(result.startIndex..<result.index(afterCharacter: result.startIndex))
            }
            while let last = result.characters.last, last.isWhitespace {
                let end = result.endIndex
                result.removeSubrange(result.index(beforeCharacter: end)..<end)
            }
            return result
        }
    }
}
