import SwiftUI

/// The shell: one tab per topic, plus everything else.
///
/// Five tabs, deliberately — iOS folds anything past five into a "More" list,
/// and a topic you read every morning does not belong behind a disclosure. So
/// the four topics get the four visible slots and Saved, Search and Settings
/// share the fifth.
///
/// There is no combined feed. Each topic is its own place with its own
/// furniture, which is the point: a screen with a live rail on it and a screen
/// with a price chart on it are not the same screen with a different filter.
struct RootView: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore

    @State private var hasLoaded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            WarScreen()
                .tabItem { Label(Topic.war.title, systemImage: Topic.war.systemImage) }

            PoliticsScreen()
                .tabItem { Label(Topic.politics.title, systemImage: Topic.politics.systemImage) }

            EconomicsScreen()
                .tabItem { Label(Topic.economics.title, systemImage: Topic.economics.systemImage) }

            GamingScreen()
                .tabItem { Label(Topic.gaming.title, systemImage: Topic.gaming.systemImage) }

            MoreScreen()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .tint(Palette.accent)
        .task {
            // Once per launch. `.task` re-runs whenever the view identity
            // changes, and a tab switch is enough to do that — without the
            // guard, every visit refires the whole catalog.
            guard !hasLoaded else { return }
            hasLoaded = true
            feed.hydrateFromCache(sources: catalog.sources)
            await refreshAll(force: false)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await refreshAll(force: false) }
            case .background:
                read.flush()
            default:
                break
            }
        }
    }

    private func refreshAll(force: Bool) async {
        await feed.refresh(
            sources: catalog.enabledSources,
            environment: settings.loadEnvironment(games: steamLibrary.activeGames),
            force: force
        )
    }
}

/// The fifth tab: everything that is not a feed.
struct MoreScreen: View {

    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var library: SteamLibraryStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SavedScreen()
                    } label: {
                        LabeledContent {
                            Text("\(read.saved.count)")
                        } label: {
                            Label("Saved", systemImage: "bookmark")
                        }
                    }

                    NavigationLink {
                        SearchScreen()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }

                Section("Feeds") {
                    NavigationLink {
                        SourcesScreen()
                    } label: {
                        LabeledContent {
                            Text("\(catalog.enabledSources.count) on")
                        } label: {
                            Label("Sources", systemImage: "dot.radiowaves.up.forward")
                        }
                    }

                    NavigationLink {
                        LiveChannelsScreen()
                    } label: {
                        Label("Streams", systemImage: "play.rectangle")
                    }

                    NavigationLink {
                        SteamScreen()
                    } label: {
                        LabeledContent {
                            Text(library.games.isEmpty ? "Not set" : "\(library.activeGames.count) games")
                                .foregroundStyle(library.games.isEmpty ? .tertiary : .secondary)
                        } label: {
                            Label("Steam", systemImage: "gamecontroller")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}
