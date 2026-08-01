import SwiftUI

/// The shell: one tab per topic, plus everything else.
///
/// Five tabs, deliberately — iOS folds anything past five into a "More" list,
/// and a topic you read every morning does not belong behind a disclosure. So
/// the four all-day sections — War, Politics, Markets, Tech — get the four
/// visible slots, and Saved, Search, Settings and the rest share the fifth.
///
/// Gaming lost its tab when Tech arrived; there is no sixth slot, and gaming is
/// the section read least like a wire — patch notes for the games you played,
/// not something happening now — so it moved into More, opened full-screen from
/// there. It is a relocation, not a removal: everything it had is intact.
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

            TechScreen()
                .tabItem { Label(Topic.tech.title, systemImage: Topic.tech.systemImage) }

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
                // Coming back to the app is a request for now, not for
                // whatever the interval setting last allowed. The floor caps
                // how stale that can be: with Refresh on "after an hour", a
                // wire that publishes every few minutes was an hour behind
                // every time the app was reopened.
                Task { await refreshAll(force: false, maximumAge: RootView.returnFloor) }
            case .background:
                read.flush()
            default:
                break
            }
        }
    }

    /// The most stale a feed may be when the app comes back to the foreground.
    ///
    /// Two minutes rather than zero so that flicking to another app and back
    /// does not refetch a dozen sources each time.
    static let returnFloor: TimeInterval = 120

    private func refreshAll(force: Bool, maximumAge: TimeInterval? = nil) async {
        var environment = settings.loadEnvironment(games: steamLibrary.activeGames)
        if let maximumAge {
            environment.staleAfter = min(environment.staleAfter, maximumAge)
        }
        await feed.refresh(
            sources: catalog.enabledSources,
            environment: environment,
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

    /// Gaming opens full-screen from here. A cover rather than a push so its own
    /// navigation stack has a clean context — a `NavigationStack` nested inside
    /// another misbehaves, and a modal is a fresh one.
    @State private var showingGaming = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingGaming = true
                    } label: {
                        Label("Gaming", systemImage: Topic.gaming.systemImage)
                    }
                    .tint(.primary)

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
            .fullScreenCover(isPresented: $showingGaming) {
                GamingScreen(onClose: { showingGaming = false })
            }
        }
    }
}
