import SwiftUI

/// The in-app reader.
///
/// Most of the built-in sources syndicate their whole article — ZeroHedge's
/// full feed and Steam's announcements both do — so this is the primary way to
/// read, not a preview with an "open in browser" button bolted on. Where a feed
/// carries only a summary, that is said plainly and the web page is one tap
/// away rather than pretending the excerpt is the piece.
struct ArticleScreen: View {

    let article: Article

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var blocks: [ArticleBlock] = []
    @State private var isParsing = true
    @State private var webLink: WebLink?

    private var source: Source? { catalog.source(id: article.sourceID) }

    private var bodyFont: Font {
        .system(size: 17 * settings.readerTextScale)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if settings.showImages, let imageURL = article.imageURL, !leadsWithSameImage {
                    RemoteImage(url: imageURL, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if isParsing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if blocks.isEmpty {
                    StateView(systemImage: "doc.plaintext",
                              title: "No article text",
                              message: "This source publishes headlines only.")
                } else {
                    ForEach(blocks) { block in
                        view(for: block)
                    }
                }

                footer
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .navigationTitle(source?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url).ignoresSafeArea()
        }
        .task(id: article.id) {
            if settings.markReadOnOpen { read.markRead(article) }
            await parse()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            SourceBadge(sourceName: source?.name ?? "Dispatch",
                        context: article.context,
                        age: nil,
                        isUnread: false)

            Text(article.displayTitle)
                .font(.system(size: 25 * min(settings.readerTextScale, 1.3), weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let author = article.author, !author.isEmpty {
                    Text(author)
                    Text("·").foregroundStyle(.tertiary)
                }
                if let published = article.published {
                    Text(published.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)

            sortingLine
        }
        .padding(.top, 8)
    }

    /// Why this story is in the section it is in.
    ///
    /// Shown because the sorting is a heuristic and a heuristic nobody can
    /// question is just a black box that is occasionally wrong. Seeing that a
    /// piece landed in Markets on "yields" and "basis points" turns a misfile
    /// into a lexicon fix.
    @ViewBuilder
    private var sortingLine: some View {
        if settings.showSortingEvidence, let verdict = feed.verdict(for: article) {
            HStack(spacing: 5) {
                Image(systemName: verdict.isFallback
                      ? "questionmark.circle"
                      : verdict.topic.systemImage)
                    .font(.system(size: 10, weight: .semibold))

                if verdict.isFallback {
                    Text("Filed under \(verdict.topic.title) by default")
                } else if verdict.evidence.isEmpty {
                    Text("\(verdict.topic.title) — this source only publishes \(verdict.topic.title.lowercased())")
                } else {
                    Text("\(verdict.topic.title) — \(verdict.evidence.joined(separator: ", "))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(TopicTheme.accent(verdict.topic))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TopicTheme.wash(verdict.topic), in: Capsule())
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let link = article.link {
            VStack(spacing: 10) {
                Divider()
                Button {
                    webLink = WebLink(url: link)
                } label: {
                    Label(isExcerptOnly ? "Read the full article" : "Open web page",
                          systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)

                Text(link.host ?? link.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func view(for block: ArticleBlock) -> some View {
        switch block.kind {
        case .paragraph(let text):
            Text(text)
                .font(bodyFont)
                .lineSpacing(4)
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let text, let level):
            Text(text)
                .font(.system(size: (level <= 2 ? 21 : 18) * settings.readerTextScale, weight: .bold))
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 3)
                Text(text)
                    .font(.system(size: 17 * settings.readerTextScale).italic())
                    .foregroundStyle(.secondary)
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let text, let marker):
            HStack(alignment: .top, spacing: 8) {
                Text(marker)
                    .font(bodyFont)
                    .foregroundStyle(Palette.accent)
                Text(text)
                    .font(bodyFont)
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .image(let url):
            if settings.showImages {
                RemoteImage(url: url, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                read.toggleSaved(article)
            } label: {
                Image(systemName: read.isSaved(article) ? "bookmark.fill" : "bookmark")
            }

            Menu {
                if let link = article.link {
                    ShareLink(item: link) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = link.absoluteString
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    Button {
                        webLink = WebLink(url: link)
                    } label: {
                        Label("Open web page", systemImage: "safari")
                    }
                }
                Button {
                    read.markUnread(article)
                } label: {
                    Label("Mark unread", systemImage: "circle")
                }

                Divider()

                Button {
                    settings.readerTextScale = min(1.6, settings.readerTextScale + 0.1)
                } label: {
                    Label("Larger text", systemImage: "textformat.size.larger")
                }
                Button {
                    settings.readerTextScale = max(0.8, settings.readerTextScale - 0.1)
                } label: {
                    Label("Smaller text", systemImage: "textformat.size.smaller")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Parsing

    /// A feed that publishes only a teaser, which the footer should say so.
    private var isExcerptOnly: Bool {
        guard let body = article.bodyHTML else { return true }
        return HTMLText.plainText(from: body).count < 600
    }

    /// True when the body already opens with the same picture as the hero, so
    /// the reader does not print it twice.
    private var leadsWithSameImage: Bool {
        guard let first = blocks.first, case .image(let url) = first.kind else { return false }
        return url == article.imageURL
    }

    private func parse() async {
        isParsing = true
        defer { isParsing = false }

        guard let html = article.bodyHTML, !html.isEmpty else {
            blocks = fallbackBlocks()
            return
        }
        let base = article.link

        // Off the main thread: a long ZeroHedge piece is a few hundred
        // kilobytes of markup, and parsing it inline drops the push animation.
        blocks = await Task.detached(priority: .userInitiated) {
            HTMLDocument.parse(html, baseURL: base)
        }.value
    }

    /// Sources with no markup at all — Telegram posts — still get paragraphs.
    private func fallbackBlocks() -> [ArticleBlock] {
        let paragraphs = article.summary
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return paragraphs.enumerated().map {
            ArticleBlock(id: $0.offset, kind: .paragraph(AttributedString($0.element)))
        }
    }
}
