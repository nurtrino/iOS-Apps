import SwiftUI

/// Everything one source has published, on its own screen.
///
/// The escape hatch for the two sources that get pulled out of their topic's
/// main list. A block on the topic screen shows the newest few; this is where
/// the rest went.
struct SourceFeedScreen: View {

    let sourceID: String

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    @State private var webLink: WebLink?

    private var source: Source? { catalog.source(id: sourceID) }

    private var articles: [Article] {
        feed.articles(for: sourceID).sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        List {
            if articles.isEmpty {
                StateView(systemImage: "tray",
                          title: "Nothing loaded",
                          message: "Pull down to refresh.")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(articles) { article in
                    row(for: article)
                        .articleActions(article) { webLink = WebLink(url: $0) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(source?.name ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    read.markAllRead(articles)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(articles.isEmpty)
            }
        }
        .refreshable {
            guard let source else { return }
            await feed.refresh(
                sources: [source],
                environment: settings.loadEnvironment(games: steamLibrary.activeGames),
                force: true
            )
        }
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
    }

    @ViewBuilder
    private func row(for article: Article) -> some View {
        let content = ArticleRow(article: article,
                                 sourceName: source?.name ?? "",
                                 style: source?.style ?? .wire,
                                 isRead: read.isRead(article),
                                 accent: TopicTheme.accent(source?.fixedTopic ?? .war))

        if settings.linkBehavior == .safari || source?.prefersWebPage == true,
           let link = article.link {
            Button {
                if settings.markReadOnOpen { read.markRead(article) }
                // Resolved rather than opened directly: for an aggregator the
                // link in the feed is a stub page, and the article is one hop
                // further on. Cached, so this is instant after the first tap.
                Task {
                    let destination = await LinkResolver.shared.destination(for: article,
                                                                            source: source)
                    webLink = WebLink(url: destination ?? link)
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: article) { content }
        }
    }
}

/// Identifies a source screen on a navigation path.
struct SourceRef: Hashable {
    let id: String
}

/// Steam news, across the top of the Gaming screen.
///
/// Patch notes for a game you played last night are the reason this section
/// exists, and they arrive a handful at a time — against three X accounts
/// posting all day, they were being pushed off the screen within an hour of a
/// refresh. Interleaving by timestamp is the wrong model when the two kinds of
/// item arrive at completely different rates, so Steam gets its own row and its
/// own space and the wire runs underneath.
struct SteamRail: View {

    /// Pushed rather than linked. A horizontal rail of `NavigationLink`s inside
    /// a single List row confuses SwiftUI's link handling — the row behaves as
    /// one destination and the back button stops matching what you tapped —
    /// so the rail reports the tap and the screen owning the path does the push.
    var onOpen: (Article) -> Void
    var onOpenAll: () -> Void

    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var all: [Article] {
        feed.articles(for: "steam").sorted { $0.sortDate > $1.sortDate }
    }

    private var articles: [Article] { Array(all.prefix(12)) }

    var body: some View {
        if !articles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("YOUR GAMES")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.8)
                    Spacer()
                    Button(action: onOpenAll) {
                        Text("All \(all.count)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(TopicTheme.accent(.gaming))
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(articles) { article in
                            Button {
                                onOpen(article)
                            } label: {
                                SteamCard(article: article, isRead: read.isRead(article))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
            }
            .padding(.top, 10)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

private struct SteamCard: View {

    let article: Article
    let isRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(url: article.imageURL)
                .frame(width: 190, height: 89)
                .clipped()
                .opacity(isRead ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 3) {
                // The game, not the source: in a rail that is entirely Steam,
                // "Steam" on every card says nothing and the game name is the
                // thing being scanned for.
                Text(article.context ?? "Steam")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(TopicTheme.accent(.gaming))
                    .lineLimit(1)

                Text(article.displayTitle)
                    .font(.system(size: 12, weight: isRead ? .regular : .semibold))
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let age = article.published?.feedAge {
                    Text(age)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 190, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(width: 190)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A high-volume wire source, bounded.
///
/// A frontline Telegram channel posts dozens of times an hour. Merged into the
/// War feed by timestamp it simply *is* the War feed — every analysis piece
/// ends up buried under a wall of one-line updates. So it gets its own section
/// showing the newest few, with the rest one tap away.
///
/// A real `Section` of ordinary rows, not a stack of rows crammed into one.
/// That was the earlier shape and it broke navigation: SwiftUI treats a List
/// row as a single destination, so several links inside one row fight over the
/// back button. One row per post, one tap target each.
struct WireSection: View {

    let sourceID: String
    let limit: Int
    var onOpen: (Article) -> Void
    var onOpenAll: () -> Void
    var onPlay: (Article) -> Void

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var source: Source? { catalog.source(id: sourceID) }
    private var all: [Article] { feed.articles(for: sourceID).sorted { $0.sortDate > $1.sortDate } }
    private var newest: [Article] { Array(all.prefix(limit)) }
    private var unread: Int { read.unreadCount(in: all) }

    var body: some View {
        if let source, !newest.isEmpty {
            Section {
                ForEach(newest) { article in
                    Button {
                        // A video post is the video. Opening the caption and
                        // making someone find a link would be losing the
                        // content it came for.
                        if article.videoURL != nil { onPlay(article) } else { onOpen(article) }
                    } label: {
                        WirePostRow(article: article, isRead: read.isRead(article))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: source.kind.systemImage)
                        .font(.system(size: 11, weight: .bold))
                    Text(source.name)
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.8)

                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TopicTheme.deep(source.fixedTopic), in: Capsule())
                    }

                    Spacer()

                    Button(action: onOpenAll) {
                        Text("All \(all.count)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(TopicTheme.accent(source.fixedTopic))
                .textCase(nil)
            }
        }
    }
}

private struct WirePostRow: View {

    let article: Article
    let isRead: Bool

    var body: some View {
        // The timestamp sits *under* the text rather than beside it. A
        // frontline post is a paragraph, not a headline, and putting the age in
        // the same row took a chunk of width off every line of it — two
        // truncated lines where three full ones fit.
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isRead ? Color.clear : TopicTheme.accent(.war))
                .frame(width: 5, height: 5)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 4) {
                Text(article.displayTitle)
                    .font(.system(size: 14, weight: isRead ? .regular : .medium))
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if article.videoURL != nil {
                        Label("Video", systemImage: "play.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TopicTheme.accent(.war))
                    }
                    if let age = article.published?.feedAge {
                        Text(age)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let thumbnail = article.imageURL {
                RemoteImage(url: thumbnail)
                    .frame(width: 54, height: 54)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(isRead ? 0.55 : 1)
                    .overlay {
                        if article.videoURL != nil {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .shadow(radius: 3)
                        }
                    }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
