import SwiftUI

/// The source list, grouped by the section each one feeds.
struct SourcesScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var newSource: Source?

    var body: some View {
        List {
            // Top is a view over every other section rather than a section
            // sources are filed under, so it never has a list of its own.
            ForEach(catalog.sections.filter { $0.id != SectionCatalog.topID }) { section in
                Section {
                    let sources = catalog.sources(in: section.id, includeDisabled: true)
                        .filter { $0.sectionID == section.id }

                    if sources.isEmpty {
                        Text("No sources")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(sources) { source in
                            NavigationLink {
                                SourceEditor(source: source)
                            } label: {
                                row(for: source)
                            }
                        }
                        .onMove { offsets, destination in
                            catalog.moveSources(in: section.id, from: offsets, to: destination)
                        }
                    }
                } header: {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newSource = Source(
                        id: "",
                        name: "",
                        kind: .rss,
                        sectionID: catalog.sections.first(where: { $0.id != SectionCatalog.topID })?.id
                            ?? SectionCatalog.topID,
                        endpoint: ""
                    )
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
        }
        .sheet(item: $newSource) { draft in
            NavigationStack {
                SourceEditor(source: draft, isNew: true)
            }
        }
    }

    private func row(for source: Source) -> some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.systemImage)
                .font(.system(size: 13))
                .frame(width: 22)
                .foregroundStyle(source.isEnabled ? Palette.accent : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(source.isEnabled ? .primary : .secondary)
                Text(detail(for: source))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !source.isEnabled {
                Text("Off")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.surfaceStrong, in: Capsule())
                    .foregroundStyle(.secondary)
            } else {
                let count = feed.articles(for: source.id).count
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func detail(for source: Source) -> String {
        switch source.kind {
        case .rss: return source.endpoint
        case .telegram: return "t.me/\(TelegramFeed.normalizeChannel(source.endpoint))"
        case .x: return "@\(XBridge.normalizeHandle(source.endpoint))"
        case .steam: return "Your Steam library"
        }
    }
}

/// Add or edit one source.
struct SourceEditor: View {

    @State var source: Source
    var isNew = false

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var steamLibrary: SteamLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var fallbackDraft = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $source.name)

                Picker("Kind", selection: $source.kind) {
                    ForEach(SourceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }

                if source.kind != .steam {
                    TextField(source.kind.endpointLabel, text: $source.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(source.kind == .rss ? .URL : .default)
                }
            } footer: {
                Text(endpointHelp)
            }

            Section("Placement") {
                Picker("Section", selection: $source.sectionID) {
                    ForEach(catalog.sections.filter { $0.id != SectionCatalog.topID }) { section in
                        Text(section.title).tag(section.id)
                    }
                }
                Picker("Row style", selection: $source.style) {
                    ForEach(SourceStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Enabled", isOn: $source.isEnabled)
            }

            if source.kind != .steam {
                Section {
                    ForEach(source.fallbackFeeds, id: \.self) { url in
                        Text(url)
                            .font(.system(size: 13))
                            .lineLimit(2)
                    }
                    .onDelete { offsets in
                        source.fallbackFeeds.remove(atOffsets: offsets)
                    }

                    HStack {
                        TextField("Add a backup feed URL", text: $fallbackDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Add") {
                            let trimmed = fallbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            source.fallbackFeeds.append(trimmed)
                            fallbackDraft = ""
                        }
                        .disabled(fallbackDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Backup feeds")
                } footer: {
                    Text("Tried in order when the address above cannot be reached. For an X "
                         + "source with no bridge configured, these are used directly.")
                }
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Label("Test this source", systemImage: "checkmark.seal")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting)

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if source.isBuiltIn {
                    Button("Reset to default") {
                        catalog.resetToDefault(sourceID: source.id)
                        if let fresh = catalog.source(id: source.id) { source = fresh }
                        testResult = nil
                    }
                }
                if !isNew {
                    Button(source.isBuiltIn ? "Turn off" : "Delete source", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New source" : source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        catalog.add(source)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        // Edits to an existing source save as they are made rather than behind
        // a Done button. There is nothing destructive to confirm, and a form
        // that silently discards work when someone swipes back is worse than
        // one that saves a half-typed URL.
        .onChange(of: source) { updated in
            guard !isNew else { return }
            catalog.update(updated)
        }
        .confirmationDialog(
            source.isBuiltIn ? "Turn off \(source.name)?" : "Delete \(source.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(source.isBuiltIn ? "Turn off" : "Delete", role: .destructive) {
                catalog.remove(sourceID: source.id)
                feed.forget(sourceID: source.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(source.isBuiltIn
                 ? "Built-in sources are kept so you can turn them back on later."
                 : "This removes the source and its cached articles.")
        }
    }

    private var isValid: Bool {
        guard !source.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch source.kind {
        case .steam: return true
        case .rss: return URL(string: source.endpoint)?.scheme != nil
        case .telegram: return !TelegramFeed.normalizeChannel(source.endpoint).isEmpty
        case .x: return !XBridge.normalizeHandle(source.endpoint).isEmpty
        }
    }

    private var endpointHelp: String {
        switch source.kind {
        case .rss:
            return "A full feed URL, for example https://example.com/feed. RSS, Atom and RDF all work."
        case .telegram:
            return "A public channel's name, with or without the @. Private channels have no web "
                + "preview and cannot be read."
        case .x:
            return "A handle, with or without the @. Reading X needs a bridge — see Settings › X "
                + "bridge. Without one, the backup feeds below are used instead."
        case .steam:
            return "Pulls news for the games in your library. Manage it in Settings › Steam."
        }
    }

    private func test() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        do {
            let result = try await SourceLoader.load(
                source,
                bridge: settings.xBridge,
                steam: settings.steamContext(games: steamLibrary.activeGames),
                limit: 10
            )
            var lines = "Loaded \(result.articles.count) item\(result.articles.count == 1 ? "" : "s")."
            if let note = result.note { lines += "\n" + note }
            if let newest = result.articles.first {
                lines += "\nNewest: \(newest.displayTitle.prefix(80))"
            }
            testResult = lines
        } catch {
            testResult = (error as? FeedError)?.errorDescription
                ?? FeedError.from(error).errorDescription
                ?? "Failed."
        }
    }
}
