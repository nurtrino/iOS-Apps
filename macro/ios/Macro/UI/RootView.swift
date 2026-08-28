import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { NewsScreen() }
                .tabItem { Label("News", systemImage: "newspaper") }

            NavigationStack { CalendarScreen() }
                .tabItem { Label("Calendar", systemImage: "calendar") }

            NavigationStack { MarketsScreen() }
                .tabItem { Label("Markets", systemImage: "chart.xyaxis.line") }

            NavigationStack { SettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
