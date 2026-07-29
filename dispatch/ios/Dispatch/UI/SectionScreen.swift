import SwiftUI

/// One section's merged feed.
struct SectionScreen: View {

    let section: FeedSection
    @Binding var webLink: WebLink?

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    private var sources: [Source] { catalog.sources(in: section.id) }
    private var articles: [Article] { feed.merged(sources: sources) }

    private var visibleArticles: [Article] {
        guard settings.hideRead else { return articles }
        // An article opened a moment ago should not vanish under the finger,
        // so "hide read" filters on what was read *before* this screenful —
        // approximated by keeping saved items, which is where a just-read
        // article most often ends up.
        return articles.filter { !read.isRead($0) || read.isSaved($0) }
    }

    private var phase: LoadPhase { feed.phase(for: sources) }

    var body: some View {
        Group {
            if sources.isEmpty {
                StateView(
                    systemImage: "tray",
                    title: "No sources in \(section.title)",
                    message: "Add one in Settings › Sources, or turn one back on."
                )
            } else if visibleArticles.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .refreshable { await refresh(force: true) }
    }

    private var list: some View {
        List {
            let advisories = feed.advisories(for: sources)
            if !advisories.isEmpty {
                AdvisoryBanner(lines: advisories)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(visibleArticles) { article in
                row(for: article)
                    .articleActions(article) { webLink = WebLink(url: $0) }
            }

            // Breathing room under the last row, so the final headline is not
            // flush against the tab bar.
            Color.clear
                .frame(height: 12)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(for article: Article) -> some View {
        let source = catalog.source(id: article.sourceID)
        let name = source?.name ?? "Dispatch"
        let style = source?.style ?? .article
        let content = ArticleRow(article: article,
                                 sourceName: name,
                                 style: style,
                                 isRead: read.isRead(article))

        // Which of these two a tap does is a setting, so the row itself has to
        // be a different view — wrapping a NavigationLink in a Button that
        // sometimes suppresses it leaves the chevron and the highlight behind.
        if settings.linkBehavior == .safari, let link = article.link {
            Button {
                if settings.markReadOnOpen { read.markRead(article) }
                webLink = WebLink(url: link)
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
        if phase.isBusy {
            StateView(systemImage: "arrow.triangle.2.circlepath",
                      title: "Loading \(section.title)…")
        } else if settings.hideRead && !articles.isEmpty {
            StateView(
                systemImage: "checkmark.circle",
                title: "All caught up",
                message: "Every story in \(section.title) has been read. Pull down to check for more.",
                actionTitle: "Show read stories",
                action: { settings.hideRead = false }
            )
        } else if let message = phase.errorMessage {
            StateView(
                systemImage: "antenna.radiowaves.left.and.right.slash",
                title: "\(section.title) is quiet",
                message: message,
                actionTitle: "Try again",
                action: { Task { await refresh(force: true) } }
            )
        } else if section.id == "gaming" && steamLibrary.games.isEmpty {
            StateView(
                systemImage: "gamecontroller",
                title: "No games yet",
                message: "Add your Steam library in Settings › Steam to get patch notes and "
                    + "announcements for the games you actually play."
            )
        } else {
            StateView(
                systemImage: "newspaper",
                title: "Nothing here yet",
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
            staleAfter: refreshInterval.seconds
        )
    }
}
