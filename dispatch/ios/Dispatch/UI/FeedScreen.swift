import SwiftUI

/// The main tab: a pill bar of sections over a pager of feeds.
///
/// Sections are a pager rather than a second row of tabs because there are six
/// of them and iOS collapses anything past five into a "More" list — which is
/// exactly the wrong place for a category you read daily. Swiping between them
/// also matches how the content is used: Top, then Wire, then whatever is
/// happening today.
struct FeedScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    @State private var selection = SectionCatalog.topID
    @State private var webLink: WebLink?
    @State private var hasLoaded = false

    @Environment(\.scenePhase) private var scenePhase

    private var sections: [FeedSection] { catalog.visibleSections }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionPills(sections: sections,
                             unreadCounts: unreadCounts,
                             selection: $selection)

                LoadingBar(isActive: isBusy)

                Divider()

                TabView(selection: $selection) {
                    ForEach(sections) { section in
                        SectionScreen(section: section, webLink: $webLink)
                            .tag(section.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle(currentSection?.title ?? "Dispatch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: Article.self) { article in
                ArticleScreen(article: article)
            }
        }
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url)
                .ignoresSafeArea()
        }
        .task {
            // Once per launch. `.task` re-runs whenever the view identity
            // changes, and a tab switch is enough to do that — without the
            // guard, every visit to this tab refires the whole catalog.
            guard !hasLoaded else { return }
            hasLoaded = true
            feed.hydrateFromCache(sources: catalog.sources)
            await refreshAll(force: false)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // Coming back from the background is the moment the cache is
                // most likely to be stale, and the moment someone is most
                // likely to want the top of the feed to be current.
                Task { await refreshAll(force: false) }
            case .background:
                read.flush()
            default:
                break
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                    read.markAllRead(currentArticles)
                } label: {
                    Label("Mark section read", systemImage: "checkmark.circle")
                }
                .disabled(currentArticles.isEmpty)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                Task { await refreshCurrent(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isBusy)
        }
    }

    // MARK: - Derived

    private var currentSection: FeedSection? {
        sections.first { $0.id == selection }
    }

    private var currentSources: [Source] {
        catalog.sources(in: selection)
    }

    private var currentArticles: [Article] {
        feed.merged(sources: currentSources)
    }

    private var isBusy: Bool {
        feed.phase(for: currentSources).isBusy
    }

    /// Unread counts for the pills.
    ///
    /// Computed across all sections in one pass rather than per pill: each pill
    /// re-evaluating on every read-state change turned into a visible hitch
    /// while scrolling a long section.
    private var unreadCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for section in sections {
            let articles = feed.merged(sources: catalog.sources(in: section.id))
            counts[section.id] = read.unreadCount(in: articles)
        }
        return counts
    }

    // MARK: - Loading

    private func refreshAll(force: Bool) async {
        await feed.refresh(
            sources: catalog.enabledSources,
            environment: settings.loadEnvironment(games: steamLibrary.activeGames),
            force: force
        )
    }

    private func refreshCurrent(force: Bool) async {
        await feed.refresh(
            sources: currentSources,
            environment: settings.loadEnvironment(games: steamLibrary.activeGames),
            force: force
        )
    }
}
