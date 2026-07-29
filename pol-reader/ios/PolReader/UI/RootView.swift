import SwiftUI

struct RootView: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            CatalogScreen()
                .tabItem { Label("/pol/", systemImage: "square.grid.2x2") }

            WatchedScreen()
                .tabItem { Label("Watched", systemImage: "bookmark") }

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Palette.accent)
    }
}
