import SwiftUI

/// War — the monitoring screen.
///
/// The stream link sits at the very top: when something is happening, getting
/// to live coverage should be the first thing on the screen. Tapping it hands
/// off to the YouTube app — the real player, the account, the resolution
/// picker — rather than playing a cropped embed in a rail. Under it the brief,
/// then the analysis merged by time.
struct WarScreen: View {

    @EnvironmentObject private var live: LiveStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var webLink: WebLink?
    /// Pushes are driven from a path rather than from links inside rails and
    /// section headers: SwiftUI treats a List row as one destination, so
    /// several links inside one row fight over the back button.
    @State private var path = NavigationPath()

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .war, webLink: $webLink) {
                WarLiveLink()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                BriefSection(topic: .war)

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
        let count = feed.articles(for: .war, from: sources).count
        return "\(count) stories from \(sources.count) source\(sources.count == 1 ? "" : "s")"
    }
}

/// The one-tap door to live war coverage, in the YouTube app.
///
/// Replaces the in-app stream rail. The rail played a cropped embed that YouTube
/// frequently refused; a link into the real app is what the streams are for. It
/// checks the same live signals the rail did so it can jump straight to a stream
/// that is on right now, and otherwise opens a war channel's live tab where the
/// next one will appear.
struct WarLiveLink: View {

    @EnvironmentObject private var live: LiveStore

    /// A war channel confirmed live, preferred so the tap lands on the stream
    /// itself rather than a channel page.
    private var liveChannel: LiveChannel? {
        live.liveNow.first { $0.topic == .war }
    }

    /// Where to send someone when nothing is confirmed live yet.
    private var fallbackReference: String {
        live.enabledChannels.first { $0.topic == .war && $0.platform == .youtube }?.reference
            ?? "@MarioNawfal"
    }

    private var isLive: Bool { liveChannel != nil }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isLive ? .red : TopicTheme.accent(.war))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isLive { LiveDot() }
                        Text(isLive ? "LIVE WAR COVERAGE" : "WAR LIVESTREAMS")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.8)
                            .foregroundStyle(isLive ? .red : TopicTheme.accent(.war))
                    }
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isLive ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var subtitle: String {
        if let liveChannel {
            return live.state(for: liveChannel)?.title ?? "\(liveChannel.name) is live — opens in YouTube"
        }
        return "Open live coverage in the YouTube app"
    }

    private func open() {
        Task {
            if let liveChannel, let videoID = live.state(for: liveChannel)?.videoID,
               await VideoLauncher.openVideo(id: videoID) {
                return
            }
            _ = await VideoLauncher.openChannelLive(reference: fallbackReference)
        }
    }
}

/// Politics.
///
/// Citizen Free Press is a fixed political source now, so it flows straight into
/// this list with everything else, newest first — no separate door, no
/// per-story classifier deciding which of three sections each of its hundred
/// daily links belongs in. The list is the stream.
struct PoliticsScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var webLink: WebLink?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .politics, webLink: $webLink) {
                BriefSection(topic: .politics)

                TopicHeader(topic: .politics, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Politics")
            .topicToolbar(.politics)
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
            .navigationDestination(for: SourceRef.self) { SourceFeedScreen(sourceID: $0.id) }
        }
        .tint(TopicTheme.accent(.politics))
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .politics)
        let count = feed.articles(for: .politics, from: sources).count
        return "\(count) stories, newest first"
    }
}

/// Markets — prices and the calendar over the classified economics feed.
///
/// No stream rail here any more: the finance channels are still in More ›
/// Streams for anyone who wants Bloomberg on in the corner, but Markets is about
/// the numbers and the calendar, and a video rail on top of a price strip was
/// two "what is happening right now" widgets stacked on one screen.
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

                BriefSection(topic: .economics)

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
        .task {
            await markets.refresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await markets.refresh(force: true) }
            }
        }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .economics)
        let count = feed.articles(for: .economics, from: sources).count
        return "\(count) stories sorted here"
    }
}

/// Tech.
///
/// The same shape as Gaming: fixed single-subject sources routed straight here,
/// no classifier in the way. Space gets its own rail across the top — Payload
/// and Next Spaceflight pulled out of the main wire the way Steam is on Gaming —
/// so "just the space news" is one tap and the general tech wire underneath is
/// not competing with it.
struct TechScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var webLink: WebLink?
    @State private var path = NavigationPath()

    /// Sources shown in the space rail rather than the main tech wire.
    static let spaceSourceIDs: Set<String> = ["payload-space", "spaceflightnow"]

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .tech, webLink: $webLink, excluding: TechScreen.spaceSourceIDs) {
                SpaceRail(onOpen: { path.append($0) },
                          onOpenAll: { path.append(SpaceRef()) })

                BriefSection(topic: .tech)

                TopicHeader(topic: .tech, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Tech")
            .topicToolbar(.tech)
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
            .navigationDestination(for: SourceRef.self) { SourceFeedScreen(sourceID: $0.id) }
            .navigationDestination(for: SpaceRef.self) { _ in
                SpaceScreen(sourceIDs: TechScreen.spaceSourceIDs)
            }
        }
        .tint(TopicTheme.accent(.tech))
        .sheet(item: $webLink) { SafariSheet(url: $0.url).ignoresSafeArea() }
    }

    private var subtitle: String {
        let sources = catalog.sources(reaching: .tech)
            .filter { !TechScreen.spaceSourceIDs.contains($0.id) }
        let count = feed.articles(for: .tech, from: sources).count
        return "\(count) stories from the tech wire"
    }
}

/// Gaming.
///
/// Reached from More rather than a tab now — Tech took the fifth slot, and iOS
/// only shows five. Presented in its own full-screen context, so `onClose` adds
/// the Done button that a modal needs and a tab does not.
struct GamingScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    var onClose: (() -> Void)? = nil

    @State private var webLink: WebLink?
    @State private var path = NavigationPath()

    static let steamSourceID = "steam"

    var body: some View {
        NavigationStack(path: $path) {
            TopicFeedList(topic: .gaming, webLink: $webLink, excluding: [GamingScreen.steamSourceID]) {
                SteamRail(onOpen: { path.append($0) },
                          onOpenAll: { path.append(SourceRef(id: GamingScreen.steamSourceID)) })

                BriefSection(topic: .gaming)

                TopicHeader(topic: .gaming, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Gaming")
            .topicToolbar(.gaming)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done", action: onClose)
                    }
                }
            }
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
