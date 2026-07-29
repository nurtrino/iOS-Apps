import SwiftUI

/// War — the monitoring screen.
///
/// The live rail sits above everything because that is the point of the
/// section: when something is happening, the stream covering it should be the
/// first thing on the screen, not four scrolls down. Below it the Telegram
/// wire and the analysis are interleaved by time, which is how a fast-moving
/// story actually reads — a frontline post at 14:02, a War Zone piece at 14:40.
struct WarScreen: View {

    @EnvironmentObject private var live: LiveStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    @State private var webLink: WebLink?
    @State private var playing: LivePlayback?
    @State private var video: Article?
    /// Pushes are driven from a path rather than from links inside rails and
    /// section headers — see `WireSection` for why that was breaking the back
    /// button.
    @State private var path = NavigationPath()

    @Environment(\.scenePhase) private var scenePhase

    /// The frontline Telegram channel. High enough volume that merging it into
    /// the main list buries everything else, so it lives in its own section.
    static let wireSourceID = "wfwitness"

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .war, webLink: $webLink, excluding: [WarScreen.wireSourceID]) {
                LiveRail(playing: $playing, webLink: $webLink)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                // The wire is excluded from the numbered rows — it has its own
                // section a few inches below — but still feeds the summary.
                BriefSection(topic: .war,
                             excluding: [WarScreen.wireSourceID]) { path.append($0) }

                WireSection(
                    sourceID: WarScreen.wireSourceID,
                    limit: 6,
                    onOpen: { path.append($0) },
                    onOpenAll: { path.append(SourceRef(id: WarScreen.wireSourceID)) },
                    onPlay: { video = $0 }
                )

                TopicHeader(topic: .war, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("War")
            .topicToolbar(.war)
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
            .navigationDestination(for: SourceRef.self) { SourceFeedScreen(sourceID: $0.id) }
        }
        .tint(TopicTheme.accent(.war))
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
        .sheet(item: $playing) { LivePlayerSheet(channel: $0.channel, state: $0.state) }
        .sheet(item: $video) { VideoSheet(article: $0) }
        .task {
            await live.refresh()
        }
        .onChange(of: scenePhase) { phase in
            // Coming back to the app is exactly when "is anything on right now"
            // is most likely to have changed.
            if phase == .active { Task { await live.refresh(force: true) } }
        }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .war)
            .filter { $0.id != WarScreen.wireSourceID }
        let count = feed.articles(for: .war, from: sources).count
        return "\(count) stories from \(sources.count) source\(sources.count == 1 ? "" : "s")"
    }
}

/// Politics.
struct PoliticsScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var webLink: WebLink?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .politics, webLink: $webLink) {
                BriefSection(topic: .politics) { path.append($0) }

                TopicHeader(topic: .politics, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Politics")
            .topicToolbar(.politics)
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
        }
        .tint(TopicTheme.accent(.politics))
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .politics)
        let count = feed.articles(for: .politics, from: sources).count
        return "\(count) stories sorted here"
    }
}

/// Markets — prices and the calendar over the classified economics feed.
struct EconomicsScreen: View {

    @EnvironmentObject private var markets: MarketStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var webLink: WebLink?
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .economics, webLink: $webLink) {
                VStack(alignment: .leading, spacing: 0) {
                    MarketStrip()
                    CalendarStrip()
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                BriefSection(topic: .economics) { path.append($0) }

                TopicHeader(topic: .economics, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Markets")
            .topicToolbar(.economics)
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
        }
        .tint(TopicTheme.accent(.economics))
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
        .task { await markets.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await markets.refresh(force: true) } }
        }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .economics)
        let count = feed.articles(for: .economics, from: sources).count
        return "\(count) stories sorted here"
    }
}

/// Gaming.
struct GamingScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    @State private var webLink: WebLink?
    @State private var path = NavigationPath()

    static let steamSourceID = "steam"

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .gaming, webLink: $webLink, excluding: [GamingScreen.steamSourceID]) {
                SteamRail(onOpen: { path.append($0) },
                          onOpenAll: { path.append(SourceRef(id: GamingScreen.steamSourceID)) })

                BriefSection(topic: .gaming,
                             excluding: [GamingScreen.steamSourceID]) { path.append($0) }

                TopicHeader(topic: .gaming, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Gaming")
            .topicToolbar(.gaming)
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
            .navigationDestination(for: SourceRef.self) { SourceFeedScreen(sourceID: $0.id) }
        }
        .tint(TopicTheme.accent(.gaming))
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .gaming)
            .filter { $0.id != GamingScreen.steamSourceID }
        let count = feed.articles(for: .gaming, from: sources).count
        return "\(count) stories from the gaming wire"
    }
}

/// The filter menu and refresh button every topic screen carries.
///
/// A `ViewModifier` rather than a `ToolbarContent` struct. `ToolbarContent` is
/// not a `View`, and whether SwiftUI installs `@EnvironmentObject` into one is
/// version-dependent enough not to bet four screens on — a modifier is a plain
/// view wrapper where dynamic properties are guaranteed to work.
struct TopicToolbar: ViewModifier {

    let topic: Topic

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    private var sources: [Source] { catalog.sources(reaching: topic) }
    private var articles: [Article] { feed.articles(for: topic, from: sources) }

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Toggle(isOn: $settings.hideRead) {
                        Label("Hide read", systemImage: "eye.slash")
                    }
                    Toggle(isOn: $settings.compactRows) {
                        Label("Compact rows", systemImage: "list.bullet")
                    }
                    Toggle(isOn: $settings.showImages) {
                        Label("Show images", systemImage: "photo")
                    }

                    Divider()

                    Button {
                        read.markAllRead(articles)
                    } label: {
                        Label("Mark \(topic.title) read", systemImage: "checkmark.circle")
                    }
                    .disabled(articles.isEmpty)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        await feed.refresh(
                            sources: sources,
                            environment: settings.loadEnvironment(games: steamLibrary.activeGames),
                            force: true
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(feed.phase(for: sources).isBusy)
            }
        }
    }
}

extension View {
    func topicToolbar(_ topic: Topic) -> some View {
        modifier(TopicToolbar(topic: topic))
    }
}
