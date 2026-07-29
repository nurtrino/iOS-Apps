import SwiftUI

/// Pushed from More, so it carries no navigation stack of its own.
struct SettingsScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    @State private var cacheSize: Int64 = 0
    @State private var confirmingReset = false
    @State private var confirmingClearRead = false

    var body: some View {
        Form {
            bridgeSection
            readingSection
            appearanceSection
            storageSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheSize = DiskStore.cacheSize() }
        .confirmationDialog("Reset all sources?",
                            isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                catalog.resetEverything()
                feed.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every source goes back to how it shipped, including how it files stories. "
                 + "Saved articles and read state are left alone.")
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

    // MARK: - Sections

    private var bridgeSection: some View {
        Section("Feeds") {
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

            Toggle(isOn: $settings.showBrief) {
                Label("Show the brief", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Toggle(isOn: $settings.showSortingEvidence) {
                Label("Show why a story was filed", systemImage: "arrow.triangle.branch")
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
            Text("The brief is the newest few headlines per topic, one per source before any "
                 + "source repeats, plus the real numbers where a topic has them. It is a digest "
                 + "of what is already there, not generated prose — nothing is sent anywhere to "
                 + "write it.\n\n"
                 + (settings.linkBehavior == .reader
                 ? "The reader uses the article text the feed itself publishes. Sources that "
                   + "syndicate only a summary show one, with the full page a tap away."
                 : "Headlines open the publisher's page in Safari. The reader is still available "
                   + "from a long press."))
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
                Label("Reset all sources", systemImage: "arrow.counterclockwise")
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
                 + "server in between and no tracking. Stories are sorted into topics on the "
                 + "phone — nothing is sent anywhere to classify it. The only credential it can "
                 + "hold is a Steam API key, which lives in the Keychain and is sent only to Valve.")
        }
    }
}

extension Bundle {
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
