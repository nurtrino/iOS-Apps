import SwiftUI

/// The list of stories under a topic, with whatever furniture that topic wants
/// above it.
///
/// All four screens share this. What differs between them is the header — a
/// live rail, a pair of price cards, a release calendar — and the accent
/// colour, so those are the only things passed in. Everything below the header
/// is the same reading experience wherever you are in the app.
struct TopicFeedList<Header: View>: View {

    let topic: Topic
    @Binding var webLink: WebLink?
    /// Sources pulled out into their own block in the header, so their items
    /// do not also appear in the main list.
    var excluding: Set<String> = []
    @ViewBuilder var header: () -> Header

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    /// Everything feeding this topic, including the sources shown separately —
    /// a refresh has to fetch those too.
    private var sources: [Source] { catalog.sources(reaching: topic) }

    private var listedSources: [Source] {
        excluding.isEmpty ? sources : sources.filter { !excluding.contains($0.id) }
    }

    private var articles: [Article] { feed.articles(for: topic, from: listedSources) }

    private var visibleArticles: [Article] {
        guard settings.hideRead else { return articles }
        return articles.filter { !read.isRead($0) || read.isSaved($0) }
    }

    private var phase: LoadPhase { feed.phase(for: sources) }

    var body: some View {
        List {
            // Emitted straight into the List rather than wrapped in a Section
            // here. A block like the Telegram wire needs to be a Section of
            // real rows — several NavigationLinks crammed into one List row is
            // what broke the back button — so the caller decides the shape.
            header()

            let advisories = feed.advisories(for: sources)
            if !advisories.isEmpty {
                AdvisoryBanner(lines: advisories)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if visibleArticles.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleArticles) { article in
                    row(for: article)
                        .articleActions(article) { webLink = WebLink(url: $0) }
                }
            }

            Color.clear
                .frame(height: 12)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .refreshable { await refresh(force: true) }
        // Switching to a tab asks that topic's sources whether they are stale.
        // Without this the only automatic refreshes were launch and returning
        // to the app, so a session spent moving between tabs read the same
        // articles for as long as it lasted. Staleness-gated, so on a topic
        // that was just fetched this costs nothing.
        .task { await refresh(force: false) }
    }

    @ViewBuilder
    private func row(for article: Article) -> some View {
        let source = catalog.source(id: article.sourceID)
        let content = ArticleRow(article: article,
                                 sourceName: source?.name ?? "Dispatch",
                                 style: source?.style ?? .article,
                                 isRead: read.isRead(article),
                                 accent: TopicTheme.accent(topic))

        // Which of these two a tap does is a setting *and* a per-source
        // override, so the row itself has to be a different view — wrapping a
        // NavigationLink in a Button that sometimes suppresses it leaves the
        // chevron and the highlight behind.
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
            NavigationLink(value: article) {
                content
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if sources.isEmpty {
            StateView(
                systemImage: "tray",
                title: "No sources feeding \(topic.title)",
                message: "Turn one on in More › Sources."
            )
        } else if phase.isBusy {
            StateView(systemImage: "arrow.triangle.2.circlepath",
                      title: "Loading \(topic.title)…")
        } else if settings.hideRead && !articles.isEmpty {
            StateView(
                systemImage: "checkmark.circle",
                title: "All caught up",
                message: "Everything in \(topic.title) has been read.",
                actionTitle: "Show read stories",
                action: { settings.hideRead = false }
            )
        } else if let message = phase.errorMessage {
            StateView(
                systemImage: "antenna.radiowaves.left.and.right.slash",
                title: "\(topic.title) is quiet",
                message: message,
                actionTitle: "Try again",
                action: { Task { await refresh(force: true) } }
            )
        } else if topic == .gaming && steamLibrary.games.isEmpty {
            StateView(
                systemImage: "gamecontroller",
                title: "Nothing yet",
                message: "Add your Steam library in More › Steam for patch notes on the games "
                    + "you actually play."
            )
        } else {
            StateView(
                systemImage: "newspaper",
                title: "Nothing sorted here yet",
                message: "Pull down to refresh.",
                actionTitle: "Refresh",
                action: { Task { await refresh(force: true) } }
            )
        }
    }

    private func refresh(force: Bool) async {
        await feed.refresh(
            sources: sources,
            environment: settings.loadEnvironment(games: steamLibrary.activeGames),
            force: force
        )
    }
}

extension TopicFeedList where Header == EmptyView {
    init(topic: Topic, webLink: Binding<WebLink?>) {
        self.init(topic: topic, webLink: webLink) { EmptyView() }
    }
}

extension SettingsStore {

    /// Gathers the settings a load depends on into one value.
    ///
    /// Passed by value into the fetch rather than read from inside it: a
    /// refresh that reads `self` from a background task would be touching main
    /// actor state from the wrong context, and a snapshot also means a setting
    /// changed mid-refresh cannot half-apply.
    func loadEnvironment(games: [SteamGame]) -> LoadEnvironment {
        LoadEnvironment(
            bridge: xBridge,
            steam: steamContext(games: games),
            itemsPerSource: itemsPerSource,
            staleAfter: refreshInterval.seconds,
            sortsWithModel: aiSorting && hasAnthropicKey
        )
    }
}

/// The heading above a topic's furniture.
struct TopicHeader: View {

    let topic: Topic
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: topic.systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(topic.title.uppercased())
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(0.8)
            }
            .foregroundStyle(TopicTheme.accent(topic))

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
