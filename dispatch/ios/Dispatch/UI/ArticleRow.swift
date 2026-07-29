import SwiftUI

/// One article, in whichever of the two shapes its source asked for.
///
/// The split is the whole reason sections feel different from each other. A
/// ZeroHedge piece and a Citizen Free Press link are not the same kind of
/// object: one is something you sit down with, the other is a headline you scan
/// forty of. Rendering both as a card with a thumbnail makes the aggregator
/// unusable; rendering both as a line makes the feature articles look like
/// nothing.
struct ArticleRow: View {

    let article: Article
    let sourceName: String
    let style: SourceStyle
    let isRead: Bool

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        switch style {
        case .article:
            if settings.compactRows {
                WireRow(article: article, sourceName: sourceName, isRead: isRead)
            } else {
                FeatureRow(article: article, sourceName: sourceName, isRead: isRead)
            }
        case .wire:
            WireRow(article: article, sourceName: sourceName, isRead: isRead)
        }
    }
}

/// Headline, dek and a thumbnail.
struct FeatureRow: View {

    let article: Article
    let sourceName: String
    let isRead: Bool

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceBadge(sourceName: sourceName,
                        context: article.context,
                        age: article.published?.feedAge,
                        isUnread: !isRead)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(article.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isRead ? .secondary : .primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.summaryDuplicatesTitle, !article.summary.isEmpty {
                        Text(article.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if settings.showImages, let imageURL = article.imageURL {
                    RemoteImage(url: imageURL)
                        .frame(width: 92, height: 92)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .opacity(isRead ? 0.55 : 1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// One dense line, for feeds you scan rather than read.
struct WireRow: View {

    let article: Article
    let sourceName: String
    let isRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.displayTitle)
                .font(.system(size: 15, weight: isRead ? .regular : .medium))
                .foregroundStyle(isRead ? .secondary : .primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            SourceBadge(sourceName: sourceName,
                        context: article.context,
                        age: article.published?.feedAge,
                        isUnread: !isRead)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The swipe actions and context menu every row shares.
///
/// Applied as a modifier rather than baked into the rows, because the same
/// actions have to work identically in a section, in search results and in the
/// saved list — three call sites that would otherwise drift apart.
struct ArticleActions: ViewModifier {

    let article: Article
    @EnvironmentObject private var read: ReadStore

    var onOpenLink: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    if read.isRead(article) { read.markUnread(article) } else { read.markRead(article) }
                } label: {
                    Label(read.isRead(article) ? "Unread" : "Read",
                          systemImage: read.isRead(article) ? "circle" : "checkmark.circle")
                }
                .tint(Palette.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    read.toggleSaved(article)
                } label: {
                    Label(read.isSaved(article) ? "Unsave" : "Save",
                          systemImage: read.isSaved(article) ? "bookmark.slash" : "bookmark")
                }
                .tint(.indigo)

                if let link = article.link {
                    ShareLink(item: link) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(.gray)
                }
            }
            .contextMenu {
                if let link = article.link {
                    Button {
                        onOpenLink(link)
                    } label: {
                        Label("Open web page", systemImage: "safari")
                    }
                    ShareLink(item: link) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = link.absoluteString
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                }
                Button {
                    read.toggleSaved(article)
                } label: {
                    Label(read.isSaved(article) ? "Remove from Saved" : "Save",
                          systemImage: read.isSaved(article) ? "bookmark.slash" : "bookmark")
                }
                Button {
                    if read.isRead(article) { read.markUnread(article) } else { read.markRead(article) }
                } label: {
                    Label(read.isRead(article) ? "Mark unread" : "Mark read",
                          systemImage: read.isRead(article) ? "circle" : "checkmark.circle")
                }
            }
    }
}

extension View {
    func articleActions(_ article: Article, onOpenLink: @escaping (URL) -> Void) -> some View {
        modifier(ArticleActions(article: article, onOpenLink: onOpenLink))
    }
}
