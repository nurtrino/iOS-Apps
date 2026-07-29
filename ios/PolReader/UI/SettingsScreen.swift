import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var filters: FilterStore

    @State private var showingFilters = false
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(settings.textScale * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.textScale, in: 0.85...1.5, step: 0.05)
                    }

                    Picker("Catalog layout", selection: $settings.catalogLayout) {
                        ForEach(CatalogLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                }

                Section {
                    Picker("Images", selection: $settings.thumbnailMode) {
                        ForEach(ThumbnailMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Reveal spoilers automatically", isOn: $settings.revealSpoilersAutomatically)
                } header: {
                    Text("Images")
                } footer: {
                    Text("/pol/ is not a worksafe board and is not moderated for graphic content. Hidden and blurred images are not downloaded until you tap them.")
                }

                Section("Reading") {
                    Picker("Thread view", selection: $settings.threadViewMode) {
                        ForEach(ThreadViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if settings.threadViewMode == .threaded {
                        Stepper(
                            settings.autoCollapseDepth == 0
                                ? "Auto-collapse: off"
                                : "Auto-collapse below depth \(settings.autoCollapseDepth)",
                            value: $settings.autoCollapseDepth,
                            in: 0...8
                        )
                    }

                    Toggle("Show poster IDs", isOn: $settings.showPosterIDs)
                    Toggle("Show country flags", isOn: $settings.showCountryFlags)
                    Toggle("Mark threads as read", isOn: $settings.markThreadsRead)
                }

                Section {
                    Picker("Auto-refresh", selection: $settings.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                } header: {
                    Text("Updating")
                } footer: {
                    Text("4chan asks that clients update a thread no more often than every 10 seconds.")
                }

                Section("Links") {
                    Toggle("Open links in app", isOn: $settings.useInAppBrowser)
                }

                Section {
                    Button {
                        showingFilters = true
                    } label: {
                        HStack {
                            Text("Filters")
                            Spacer()
                            Text(filters.filters.isEmpty ? "None" : "\(filters.filters.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Hide posts and threads matching a word or pattern. Hiding a post hides the replies underneath it.")
                }

                Section("Storage") {
                    Button("Clear read history") {
                        library.clearRead()
                    }
                    Button(cacheCleared ? "Cache cleared" : "Clear image and data cache") {
                        Task {
                            await ImageLoader.shared.clearCache()
                            await ChanAPI.shared.resetCache()
                            CommentParserCache.shared.clear()
                            cacheCleared = true
                        }
                    }
                    .disabled(cacheCleared)
                }

                Section {
                    if let url = MediaURL.webBoard("pol") {
                        Link("Open /pol/ in browser", destination: url)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("An unofficial, read-only reader for 4chan's /pol/, built on the public read-only JSON API. It cannot post, reply or vote — 4chan publishes no write API. Not affiliated with 4chan.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingFilters) {
                FilterListScreen()
            }
        }
    }
}

/// Filter management.
struct FilterListScreen: View {

    @EnvironmentObject private var filters: FilterStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftPattern = ""
    @State private var draftField: FilterField = .comment
    @State private var draftIsRegex = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Add a filter") {
                    TextField("Word or pattern", text: $draftPattern)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Match against", selection: $draftField) {
                        ForEach(FilterField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    Toggle("Regular expression", isOn: $draftIsRegex)
                    Button("Add Filter") {
                        let trimmed = draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        filters.add(PostFilter(pattern: trimmed, field: draftField, isRegex: draftIsRegex))
                        draftPattern = ""
                    }
                    .disabled(draftPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if filters.filters.isEmpty {
                    Section {
                        Text("No filters yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Active filters") {
                        ForEach(filters.filters) { filter in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(filter.pattern)
                                    .font(.system(.body, design: filter.isRegex ? .monospaced : .default))
                                Text("\(filter.field.title)\(filter.isRegex ? " · regex" : "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { filters.remove(at: $0) }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Shown once, on first launch.
struct ContentNoticeSheet: View {

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 44))
                .foregroundStyle(Palette.accent)

            Text("About this board")
                .font(.title2.weight(.semibold))

            Text("""
                 /pol/ is 4chan's politics board. It is anonymous, effectively \
                 unmoderated, and routinely contains graphic imagery and \
                 extreme content. This reader shows what the board contains, \
                 unfiltered except by settings you choose.

                 Images are blurred by default and filters are available in \
                 Settings. This app is read-only — 4chan publishes no write \
                 API, so nothing here can post, reply or vote.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8)

            Spacer()

            Button {
                settings.hasSeenContentNotice = true
                dismiss()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
        }
        .padding(24)
        .interactiveDismissDisabled()
    }
}
