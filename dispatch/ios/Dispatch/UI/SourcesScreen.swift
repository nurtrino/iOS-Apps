import SwiftUI

/// The source list, grouped by where each one files its stories.
struct SourcesScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore

    @State private var newSource: Source?

    /// Sources whose topic is decided per story, listed apart from the fixed
    /// ones because "which section is this in" has no single answer for them.
    private var classifiedSources: [Source] {
        catalog.sources.filter { $0.topicMode == .classified }
    }

    var body: some View {
        List {
            if !classifiedSources.isEmpty {
                Section {
                    ForEach(classifiedSources) { source in
                        NavigationLink { SourceEditor(source: source) } label: { row(for: source) }
                    }
                } header: {
                    Label("Sorted per story", systemImage: "arrow.triangle.branch")
                } footer: {
                    Text("These publish more than one kind of news, so each story is scored and "
                         + "filed into War, Politics or Markets on its own.")
                }
            }

            ForEach(Topic.allCases) { topic in
                let sources = catalog.sourcesFiled(under: topic)
                    .filter { $0.topicMode == .fixed }

                if !sources.isEmpty {
                    Section {
                        ForEach(sources) { source in
                            NavigationLink { SourceEditor(source: source) } label: { row(for: source) }
                        }
                        .onMove { offsets, destination in
                            catalog.moveSources(filedUnder: topic, from: offsets, to: destination)
                        }
                    } header: {
                        Label(topic.title, systemImage: topic.systemImage)
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newSource = Source(id: "", name: "", kind: .rss, endpoint: "",
                                       topicMode: .fixed, fixedTopic: .politics)
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
                .foregroundStyle(source.isEnabled
                                 ? TopicTheme.accent(source.fixedTopic)
                                 : Color.secondary)

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

            filingSection

            if source.kind != .steam {
                backupSection
            }

            testSection

            Section {
                if source.isBuiltIn {
                    Button("Reset to default") {
                        catalog.resetToDefault(sourceID: source.id)
                        if let fresh = catalog.source(id: source.id) { source = fresh }
                        feed.reclassify(sources: catalog.sources)
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
            // Changing how a source files its stories has to re-file the ones
            // already loaded, or the change appears to do nothing until the
            // next refresh.
            feed.reclassify(sources: catalog.sources)
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

    private var backupSection: some View {
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

    private var testSection: some View {
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
    }

    /// Extracted from `body` rather than inlined.
    ///
    /// Two pickers, four toggles and a footer of conditional prose is enough for
    /// the Swift type checker to give up on the whole `Form` — it did, on CI,
    /// twice. Splitting the section out and building its footer as a plain
    /// `String` array keeps each expression small enough to solve.
    private var filingSection: some View {
        Section {
            Picker("Topic", selection: $source.topicMode) {
                ForEach(TopicMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Picker(source.topicMode == .fixed ? "Files under" : "When unsure, file under",
                   selection: $source.fixedTopic) {
                ForEach(Topic.allCases) { topic in
                    Label(topic.title, systemImage: topic.systemImage).tag(topic)
                }
            }

            if source.topicMode == .classified {
                Picker("Usually about", selection: priorBinding) {
                    ForEach(Topic.classifiable) { topic in
                        Text(topic.title).tag(topic)
                    }
                }

                Toggle("Skip stories that fit nowhere", isOn: $source.dropsUnsortable)
            }

            Picker("Row style", selection: $source.style) {
                ForEach(SourceStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            Toggle("Open the web page", isOn: $source.prefersWebPage)
            Toggle("Follow to the linked article", isOn: $source.resolvesOutboundLink)
            Toggle("Enabled", isOn: $source.isEnabled)
        } header: {
            Text("Filing")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(filingHelp, id: \.self) { paragraph in
                    Text(paragraph)
                }
            }
        }
    }

    private var priorBinding: Binding<Topic> {
        Binding(get: { source.topicPrior ?? source.fixedTopic },
                set: { source.topicPrior = $0 })
    }

    private var filingHelp: [String] {
        var lines: [String] = []

        if source.topicMode == .fixed {
            lines.append("Everything from this source goes to \(source.fixedTopic.title). "
                         + "Right for a source that only ever publishes one kind of news.")
        } else {
            lines.append("Each story is scored against the War, Politics and Markets "
                         + "vocabularies and filed by whichever wins. “Usually about” breaks a "
                         + "tie between two that both scored.")
            lines.append("“Skip stories that fit nowhere” lets Claude drop a story it judges to "
                         + "belong in none of the sections — sport, celebrity, a viral video. "
                         + "Right for an aggregator that posts those next to the news. It needs "
                         + "sorting turned on in Settings › Claude: the term list alone never "
                         + "hides anything, because a word it does not know is not the same thing "
                         + "as a story that fits nowhere. Skipped stories are still on this "
                         + "source's own screen and in Search.")
        }

        lines.append("“Open the web page” skips the reader — right for a link aggregator, whose "
                     + "items are pointers to somebody else's article rather than articles of "
                     + "their own.")
        lines.append("“Follow to the linked article” goes one hop further, past the aggregator's "
                     + "own stub page to the article it points at. Without it you land on a "
                     + "headline with a “Go To Article” link under it.")
        return lines
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
            return "Pulls news for the games in your library. Manage it in More › Steam."
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

            // For a classified source, showing where the sample actually landed
            // is the fastest way to see whether the filing is sane.
            if source.topicMode == .classified, !result.articles.isEmpty {
                var counts: [Topic: Int] = [:]
                var guessed = 0
                for article in result.articles {
                    let verdict = article.classified(using: source)
                    if let topic = verdict.topic { counts[topic, default: 0] += 1 }
                    if verdict.isFallback { guessed += 1 }
                }
                var parts = Topic.classifiable
                    .compactMap { topic in counts[topic].map { "\(topic.title) \($0)" } }
                // The number that matters on an aggregator: how many of these the
                // term list had no words for and placed by the source's default.
                // Those are the ones Claude is for.
                if guessed > 0 { parts.append("guessed \(guessed)") }
                let summary = parts.joined(separator: " · ")
                if !summary.isEmpty { lines += "\nTerm list: " + summary }
            }
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
