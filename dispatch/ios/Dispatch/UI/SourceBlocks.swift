import SwiftUI

/// Everything one source has published, on its own screen.
///
/// The escape hatch for a source pulled out of its topic's main list. A block on
/// the topic screen shows the newest few; this is where the rest went.
struct SourceFeedScreen: View {

    let sourceID: String

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    @State private var webLink: WebLink?
    @State private var playingEmbed: EmbedPlayback?

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
        .sheet(item: $playingEmbed) { VideoEmbedSheet(playback: $0) }
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
                // Same routing as the topic lists: resolve the aggregator's
                // stub to its destination, send YouTube to the YouTube app,
                // and play anything else in place rather than opening the page
                // around it.
                Task {
                    let destination = await LinkResolver.shared.destination(for: article,
                                                                            source: source)
                    let target = destination ?? link
                    if let embed = VideoEmbedFinder.find(link: target,
                                                         bodyHTML: article.bodyHTML,
                                                         fileURL: article.videoURL) {
                        if await VideoLauncher.openInYouTubeApp(embed) { return }
                        playingEmbed = EmbedPlayback(embed: embed, title: article.displayTitle)
                    } else {
                        webLink = WebLink(url: target)
                    }
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

/// A named door into one source's raw stream.
///
/// This exists for the source you actually go looking for. Citizen Free Press
/// posts a hundred links a day and the classifier spreads them across three
/// sections — correct filing, but it means "just show me CFP" had no answer
/// short of the management screens. This is that answer: one tap, every post,
/// newest first, no filing in between. After a stretch where those stories were
/// genuinely going missing, the guaranteed view is also the trust-restoring one.
struct SourceSpotlight: View {

    let sourceID: String
    var onOpen: () -> Void

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var source: Source? { catalog.source(id: sourceID) }
    private var articles: [Article] { feed.articles(for: sourceID) }

    private var newest: Article? {
        articles.max { $0.sortDate < $1.sortDate }
    }

    var body: some View {
        if let source {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TopicTheme.accent(source.fixedTopic))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(source.name.uppercased())
                                .font(.system(size: 12, weight: .heavy))
                                .tracking(0.8)
                                .foregroundStyle(TopicTheme.accent(source.fixedTopic))

                            let unread = read.unreadCount(in: articles)
                            if unread > 0 {
                                Text("\(unread)")
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(TopicTheme.deep(source.fixedTopic), in: Capsule())
                                    .foregroundStyle(TopicTheme.accent(source.fixedTopic))
                            }
                        }

                        // The newest headline, so the door says whether anything
                        // is behind it — a teaser beats a label.
                        if let newest {
                            HStack(spacing: 4) {
                                Text(newest.displayTitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let age = newest.published?.feedAge {
                                    Text(age)
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } else {
                            Text("The raw stream — every post, unsorted")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 6)

                    Text("\(articles.count)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }
}
