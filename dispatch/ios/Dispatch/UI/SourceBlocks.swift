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

/// Identifies the combined space screen on a navigation path.
struct SpaceRef: Hashable {}

/// Space news, across the top of the Tech screen.
///
/// The same idea as the Steam rail on Gaming: a couple of single-subject
/// sources — Payload and Next Spaceflight — pulled out of the main tech wire so
/// launches and space-industry news are their own glanceable row rather than
/// being interleaved with chip news and platform politics. The wire runs
/// underneath; this is the shortcut to just the space stories.
struct SpaceRail: View {

    /// Pushed rather than linked, for the same reason the Steam rail is: a
    /// horizontal row of `NavigationLink`s inside one List row confuses
    /// SwiftUI's back button, so the rail reports the tap and the screen that
    /// owns the path does the push.
    var onOpen: (Article) -> Void
    var onOpenAll: () -> Void

    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var all: [Article] {
        TechScreen.spaceSourceIDs
            .flatMap { feed.articles(for: $0) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var articles: [Article] { Array(all.prefix(12)) }

    var body: some View {
        if !articles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 11, weight: .bold))
                    Text("SPACE")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.8)
                    Spacer()
                    Button(action: onOpenAll) {
                        Text("All \(all.count)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(TopicTheme.accent(.tech))
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(articles) { article in
                            Button {
                                onOpen(article)
                            } label: {
                                SpaceCard(article: article, isRead: read.isRead(article))
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

private struct SpaceCard: View {

    let article: Article
    let isRead: Bool

    @EnvironmentObject private var catalog: CatalogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(url: article.imageURL)
                .frame(width: 190, height: 89)
                .clipped()
                .opacity(isRead ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(catalog.source(id: article.sourceID)?.name ?? "Space")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(TopicTheme.accent(.tech))
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

/// Every space story, from every space source, in one list.
///
/// The "All" door on the space rail. Several sources merged and sorted by time,
/// rather than one source's screen — "the space news" is the whole beat, not one
/// outlet's slice of it.
struct SpaceScreen: View {

    let sourceIDs: Set<String>

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    private var articles: [Article] {
        sourceIDs
            .flatMap { feed.articles(for: $0) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        List {
            if articles.isEmpty {
                StateView(systemImage: "airplane",
                          title: "No space news yet",
                          message: "Pull down on Tech to refresh.")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(articles) { article in
                    NavigationLink(value: article) {
                        ArticleRow(article: article,
                                   sourceName: catalog.source(id: article.sourceID)?.name ?? "",
                                   style: catalog.source(id: article.sourceID)?.style ?? .wire,
                                   isRead: read.isRead(article),
                                   accent: TopicTheme.accent(.tech))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Space")
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
    }
}
