import SwiftUI

/// The shell: four tabs.
///
/// Sections live inside Feed rather than being tabs of their own — there are
/// six of them and iOS folds anything past five into a "More" list, which is
/// the last place a category you read every morning should be.
struct RootView: View {

    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    var body: some View {
        TabView {
            FeedScreen()
                .tabItem { Label("Feed", systemImage: "newspaper") }

            SearchScreen()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SavedScreen()
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .badge(read.saved.count)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Palette.accent)
    }
}
