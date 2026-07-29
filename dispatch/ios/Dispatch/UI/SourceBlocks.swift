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
                webLink = WebLink(url: link)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: article) { content }
        }
    }
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

    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var articles: [Article] {
        Array(feed.articles(for: "steam")
            .sorted { $0.sortDate > $1.sortDate }
            .prefix(12))
    }

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
                    NavigationLink {
                        SourceFeedScreen(sourceID: "steam")
                    } label: {
                        Text("All \(feed.articles(for: "steam").count)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(TopicTheme.accent(.gaming))
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(articles) { article in
                            NavigationLink(value: article) {
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
/// ends up buried under a wall of one-line updates. So it gets a fixed-height
/// block showing the newest few, with the rest one tap away, and the main list
/// goes back to being readable.
struct WireBlock: View {

    let sourceID: String
    let limit: Int

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var source: Source? { catalog.source(id: sourceID) }
    private var all: [Article] { feed.articles(for: sourceID).sorted { $0.sortDate > $1.sortDate } }
    private var newest: [Article] { Array(all.prefix(limit)) }

    private var unread: Int { read.unreadCount(in: all) }

    var body: some View {
        if let source, !newest.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: source.kind.systemImage)
                        .font(.system(size: 11, weight: .bold))
                    Text(source.name.uppercased())
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

                    NavigationLink {
                        SourceFeedScreen(sourceID: sourceID)
                    } label: {
                        Text("All \(all.count)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(TopicTheme.accent(source.fixedTopic))
                .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(newest) { article in
                        NavigationLink(value: article) {
                            WirePostRow(article: article, isRead: read.isRead(article))
                        }
                        .buttonStyle(.plain)

                        if article.id != newest.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
            .padding(.top, 10)
        }
    }
}

private struct WirePostRow: View {

    let article: Article
    let isRead: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(isRead ? Color.clear : TopicTheme.accent(.war))
                .frame(width: 5, height: 5)
                .padding(.top, 5)

            Text(article.displayTitle)
                .font(.system(size: 13, weight: isRead ? .regular : .medium))
                .foregroundStyle(isRead ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let age = article.published?.feedAge {
                Text(age)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
