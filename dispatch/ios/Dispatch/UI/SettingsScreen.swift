import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var library: SteamLibraryStore

    @State private var cacheSize: Int64 = 0
    @State private var confirmingReset = false
    @State private var confirmingClearRead = false

    var body: some View {
        NavigationStack {
            Form {
                feedsSection
                readingSection
                appearanceSection
                storageSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task { cacheSize = DiskStore.cacheSize() }
            .confirmationDialog("Reset sections and sources?",
                                isPresented: $confirmingReset,
                                titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    catalog.resetEverything()
                    feed.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every source goes back to how it shipped. Saved articles and read state are "
                     + "left alone.")
            }
            .confirmationDialog("Clear read state?",
                                isPresented: $confirmingClearRead,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { read.clearReadState() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every story becomes unread again.")
            }
        }
    }

    // MARK: - Sections

    private var feedsSection: some View {
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
                SectionsScreen()
            } label: {
                LabeledContent {
                    Text("\(catalog.sections.count)")
                } label: {
                    Label("Sections", systemImage: "square.grid.2x2")
                }
            }

            NavigationLink {
                XBridgeScreen()
            } label: {
                LabeledContent {
                    Text(settings.xBridge.isConfigured ? settings.xBridge.kind.title : "Not set")
                        .foregroundStyle(settings.xBridge.isConfigured ? .secondary : .tertiary)
                } label: {
                    Label("X bridge", systemImage: "at")
                }
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
    }

    private var readingSection: some View {
        Section {
            Picker(selection: $settings.linkBehavior) {
                ForEach(LinkBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            } label: {
                Label("Headlines open in", systemImage: "doc.text")
            }

            Picker(selection: $settings.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Toggle(isOn: $settings.markReadOnOpen) {
                Label("Mark read when opened", systemImage: "checkmark.circle")
            }

            Toggle(isOn: $settings.hideRead) {
                Label("Hide read stories", systemImage: "eye.slash")
            }

            Stepper(value: $settings.itemsPerSource, in: 10...200, step: 10) {
                LabeledContent {
                    Text("\(settings.itemsPerSource)")
                } label: {
                    Label("Items per source", systemImage: "list.number")
                }
            }
        } header: {
            Text("Reading")
        } footer: {
            Text(settings.linkBehavior == .reader
                 ? "The reader uses the article text the feed itself publishes. Sources that "
                   + "syndicate only a summary show one, with the full page a tap away."
                 : "Headlines open the publisher's page in Safari. The reader is still available "
                   + "from a long press.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }

            Toggle(isOn: $settings.showImages) {
                Label("Show images", systemImage: "photo")
            }

            Toggle(isOn: $settings.compactRows) {
                Label("Compact rows", systemImage: "list.bullet")
            }

            HStack {
                Label("Reader text", systemImage: "textformat.size")
                Spacer()
                Text(String(format: "%.0f%%", settings.readerTextScale * 100))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: $settings.readerTextScale, in: 0.8...1.6, step: 0.1)
                    .labelsHidden()
            }
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
            } label: {
                Label("Cached feeds", systemImage: "internaldrive")
            }

            Button {
                feed.clearAll()
                Task {
                    await ImageLoader.shared.clearCache()
                    cacheSize = DiskStore.cacheSize()
                }
            } label: {
                Label("Clear cache", systemImage: "trash")
            }

            Button {
                confirmingClearRead = true
            } label: {
                Label("Clear read state", systemImage: "circle.dashed")
            }

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label("Reset sources and sections", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Cached feeds are what make the app open to news instead of a spinner. Clearing "
                 + "them costs one refresh, nothing more.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.versionString)
            LabeledContent("Saved articles", value: "\(read.saved.count)")
            LabeledContent("Stories loaded", value: "\(feed.everyArticle.count)")
        } header: {
            Text("About")
        } footer: {
            Text("Dispatch reads public feeds directly from the device. There is no account, no "
                 + "server in between and no tracking. The only credential it can hold is a Steam "
                 + "API key, which lives in the Keychain and is sent only to Valve.")
        }
    }
}

/// Reorder, rename and add the sections that appear in the pill bar.
struct SectionsScreen: View {

    @EnvironmentObject private var catalog: CatalogStore

    @State private var newTitle = ""
    @State private var newSymbol = "square.grid.2x2"

    private static let symbolChoices = [
        "square.grid.2x2", "newspaper", "bolt.horizontal", "chart.line.uptrend.xyaxis",
        "list.bullet.rectangle", "shield", "gamecontroller", "globe", "flame",
        "building.columns", "airplane", "cpu", "cross.case", "sportscourt",
    ]

    var body: some View {
        List {
            Section {
                ForEach(catalog.sections) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(Palette.accent)
                        Text(section.title)
                        Spacer()
                        Text("\(catalog.sources(in: section.id).count)")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .onMove { catalog.moveSections(from: $0, to: $1) }
                .onDelete { offsets in
                    for index in offsets where catalog.sections.indices.contains(index) {
                        catalog.removeSection(id: catalog.sections[index].id)
                    }
                }
            } header: {
                Text("Order")
            } footer: {
                Text("This is the order of the pills above the feed. Built-in sections cannot be "
                     + "deleted; a section with no enabled sources is hidden instead.")
            }

            Section("Add a section") {
                TextField("Name", text: $newTitle)

                Picker("Icon", selection: $newSymbol) {
                    ForEach(SectionsScreen.symbolChoices, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
                .pickerStyle(.navigationLink)

                Button("Add section") {
                    catalog.addSection(title: newTitle.trimmingCharacters(in: .whitespaces),
                                       systemImage: newSymbol)
                    newTitle = ""
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Sections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}

extension Bundle {
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
