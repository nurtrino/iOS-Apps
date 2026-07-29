import SwiftUI

/// Internal URL scheme used to make quotelinks tappable.
///
/// SwiftUI's `Text` can carry links but not arbitrary tap targets, so quotelinks
/// are encoded as URLs in a private scheme and intercepted by an `openURL`
/// handler. That keeps the whole comment in a single `Text`, which is what
/// makes it wrap and select like prose instead of like a row of separate views.
enum CommentLink {
    static let scheme = "polreader"

    static func post(_ no: Int) -> URL? {
        URL(string: "\(scheme)://post/\(no)")
    }

    static func crossThread(board: String, thread: Int, post: Int) -> URL? {
        URL(string: "\(scheme)://thread/\(board)/\(thread)/\(post)")
    }

    static func board(_ board: String) -> URL? {
        URL(string: "\(scheme)://board/\(board)")
    }

    /// What a `polreader://` URL means. Returns nil for anything else.
    static func parse(_ url: URL) -> Action? {
        guard url.scheme == scheme else { return nil }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        switch parts.first {
        case "post":
            guard parts.count >= 2, let no = Int(parts[1]) else { return nil }
            return .post(no)
        case "thread":
            guard parts.count >= 4, let thread = Int(parts[2]), let post = Int(parts[3]) else { return nil }
            return .thread(board: parts[1], thread: thread, post: post)
        case "board":
            guard parts.count >= 2 else { return nil }
            return .board(parts[1])
        default:
            return nil
        }
    }

    enum Action: Equatable {
        case post(Int)
        case thread(board: String, thread: Int, post: Int)
        case board(String)
    }
}

/// Renders a parsed comment.
struct CommentBody: View {

    let blocks: [CommentBlock]
    var textScale: Double = 1.0
    /// Spoilers stay blacked out until the reader taps the comment, unless the
    /// setting says otherwise.
    var spoilersRevealed: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let paragraph):
                    Text(attributed(paragraph))
                        .font(.system(size: 15 * textScale))
                        .fixedSize(horizontal: false, vertical: true)

                case .code(let code):
                    // Its own horizontal scroller — the reason the parser emits
                    // blocks rather than one attributed string.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 13 * textScale, design: .monospaced))
                            .padding(8)
                    }
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func attributed(_ paragraph: CommentParagraph) -> AttributedString {
        var result = AttributedString(paragraph.text)
        let count = paragraph.text.count

        for span in paragraph.spans {
            guard span.start >= 0, span.length > 0, span.end <= count else { continue }
            guard let lower = result.index(result.startIndex,
                                           offsetByCharacters: span.start,
                                           limitedBy: result.endIndex),
                  let upper = result.index(lower,
                                           offsetByCharacters: span.length,
                                           limitedBy: result.endIndex)
            else { continue }
            let range = lower..<upper

            switch span.style {
            case .italic:
                result[range].inlinePresentationIntent = .emphasized

            case .bold:
                result[range].inlinePresentationIntent = .stronglyEmphasized

            case .underline:
                result[range].underlineStyle = .single

            case .greentext:
                result[range].foregroundColor = Palette.greentext(for: colorScheme)

            case .spoiler:
                if spoilersRevealed {
                    result[range].backgroundColor = Color.secondary.opacity(0.25)
                } else {
                    // Same colour as the background it sits on: the text is
                    // present and selectable but unreadable until revealed.
                    result[range].foregroundColor = .primary
                    result[range].backgroundColor = .primary
                }

            case .deadlink:
                result[range].foregroundColor = Palette.deadlink
                result[range].strikethroughStyle = .single

            case .inlineCode, .shiftJIS:
                result[range].font = .system(size: 14 * textScale, design: .monospaced)

            case .link(let raw):
                result[range].foregroundColor = Palette.externalLink
                result[range].underlineStyle = .single
                if let url = URL(string: raw) {
                    result[range].link = url
                }

            case .quotelink(let board, let thread, let post):
                result[range].foregroundColor = Palette.quotelink
                result[range].underlineStyle = .single
                if let board, let thread {
                    result[range].link = CommentLink.crossThread(board: board, thread: thread, post: post)
                } else {
                    result[range].link = CommentLink.post(post)
                }

            case .boardLink(let board):
                result[range].foregroundColor = Palette.quotelink
                result[range].underlineStyle = .single
                result[range].link = CommentLink.board(board)
            }
        }

        return result
    }
}
