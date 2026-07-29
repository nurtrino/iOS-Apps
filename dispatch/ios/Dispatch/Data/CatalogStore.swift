import Foundation

/// The sections and sources, as edited.
///
/// The built-in catalog is a *default*, not a fixture: every field of every
/// built-in source can be changed, and the change persists. What cannot happen
/// is deleting a built-in outright — it is disabled instead — so a bad edit is
/// always one "Reset to default" away from working again, and the app never
/// reaches a state where the only way back is deleting it from the phone.
@MainActor
final class CatalogStore: ObservableObject {

    @Published private(set) var sections: [FeedSection]
    @Published private(set) var sources: [Source]

    private let sectionsFile = "sections"
    private let sourcesFile = "sources"

    init(load: Bool = true) {
        guard load else {
            sections = SectionCatalog.defaults
            sources = SourceCatalog.defaults
            return
        }

        let storedSections = DiskStore.load([FeedSection].self, from: sectionsFile)
        let storedSources = DiskStore.load([Source].self, from: sourcesFile)

        sections = CatalogStore.merge(stored: storedSections,
                                      defaults: SectionCatalog.defaults,
                                      id: \.id,
                                      isBuiltIn: \.isBuiltIn)
        sources = CatalogStore.merge(stored: storedSources,
                                     defaults: SourceCatalog.defaults,
                                     id: \.id,
                                     isBuiltIn: \.isBuiltIn)
    }

    /// Stored order wins; built-ins the stored copy has never seen are appended.
    ///
    /// The append is what lets a later version ship a new source and have it
    /// appear for someone who already has a catalog on disk. Without it, new
    /// built-ins are invisible to every existing install — the classic way a
    /// feature ships to nobody.
    private static func merge<T>(stored: [T]?,
                                 defaults: [T],
                                 id: KeyPath<T, String>,
                                 isBuiltIn: KeyPath<T, Bool>) -> [T] {
        guard let stored, !stored.isEmpty else { return defaults }
        let known = Set(stored.map { $0[keyPath: id] })
        let additions = defaults.filter { $0[keyPath: isBuiltIn] && !known.contains($0[keyPath: id]) }
        return stored + additions
    }

    // MARK: - Queries

    func section(id: String) -> FeedSection? {
        sections.first { $0.id == id }
    }

    /// Enabled sources for a section, in catalog order.
    ///
    /// "Top" is not a section anyone files a source under — it is the union of
    /// everything else, which is why it is special-cased here rather than
    /// stored with a source list of its own.
    func sources(in sectionID: String, includeDisabled: Bool = false) -> [Source] {
        sources.filter { source in
            guard includeDisabled || source.isEnabled else { return false }
            return sectionID == SectionCatalog.topID || source.sectionID == sectionID
        }
    }

    var enabledSources: [Source] {
        sources.filter(\.isEnabled)
    }

    func source(id: String) -> Source? {
        sources.first { $0.id == id }
    }

    /// Sections that have at least one enabled source, plus Top.
    ///
    /// An empty tab is worse than a missing one: it reads as breakage rather
    /// than as a section nobody has filled.
    var visibleSections: [FeedSection] {
        sections.filter { section in
            section.id == SectionCatalog.topID || !sources(in: section.id).isEmpty
        }
    }

    // MARK: - Mutation

    func update(_ source: Source) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        persistSources()
    }

    func setEnabled(_ enabled: Bool, forSourceID id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        persistSources()
    }

    func add(_ source: Source) {
        var candidate = source
        candidate.id = uniqueID(basedOn: source.id.isEmpty ? source.name : source.id)
        candidate.isBuiltIn = false
        sources.append(candidate)
        persistSources()
    }

    /// Built-ins are disabled rather than removed; anything else really goes.
    func remove(sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        if sources[index].isBuiltIn {
            sources[index].isEnabled = false
        } else {
            sources.remove(at: index)
            FeedCache.delete(sourceID: sourceID)
        }
        persistSources()
    }

    func resetToDefault(sourceID: String) {
        guard let fresh = SourceCatalog.default(withID: sourceID),
              let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index] = fresh
        persistSources()
    }

    func moveSources(in sectionID: String, from offsets: IndexSet, to destination: Int) {
        // The rows being reordered are a filtered view of `sources`, so the
        // move is applied to that slice and written back by identity. Applying
        // the offsets to the full array directly would move the wrong rows the
        // moment any source is disabled or belongs to another section.
        var slice = sources(in: sectionID, includeDisabled: true)
        slice.move(fromOffsets: offsets, toOffset: destination)

        let movedIDs = Set(slice.map(\.id))
        var reordered: [Source] = []
        var iterator = slice.makeIterator()

        for source in sources {
            if movedIDs.contains(source.id) {
                if let next = iterator.next() { reordered.append(next) }
            } else {
                reordered.append(source)
            }
        }
        sources = reordered
        persistSources()
    }

    func addSection(title: String, systemImage: String) {
        let id = uniqueSectionID(basedOn: title)
        sections.append(FeedSection(id: id, title: title, systemImage: systemImage))
        persistSections()
    }

    func removeSection(id: String) {
        guard let section = section(id: id), !section.isBuiltIn else { return }
        sections.removeAll { $0.id == id }
        // Orphaned sources would vanish from every screen while still being
        // fetched. Move them somewhere visible instead.
        for index in sources.indices where sources[index].sectionID == id {
            sources[index].sectionID = SectionCatalog.defaults.first?.id ?? SectionCatalog.topID
        }
        persistSections()
        persistSources()
    }

    func moveSections(from offsets: IndexSet, to destination: Int) {
        sections.move(fromOffsets: offsets, toOffset: destination)
        persistSections()
    }

    func resetEverything() {
        sections = SectionCatalog.defaults
        sources = SourceCatalog.defaults
        persistSections()
        persistSources()
    }

    // MARK: - Helpers

    private func uniqueID(basedOn seed: String) -> String {
        let base = seed.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        var candidate = String(base).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if candidate.isEmpty { candidate = "source" }

        var unique = candidate
        var suffix = 2
        while sources.contains(where: { $0.id == unique }) {
            unique = "\(candidate)-\(suffix)"
            suffix += 1
        }
        return unique
    }

    private func uniqueSectionID(basedOn seed: String) -> String {
        let base = seed.lowercased().filter { $0.isLetter || $0.isNumber }
        var candidate = base.isEmpty ? "section" : base
        var suffix = 2
        while sections.contains(where: { $0.id == candidate }) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func persistSources() {
        DiskStore.save(sources, to: sourcesFile)
    }

    private func persistSections() {
        DiskStore.save(sections, to: sectionsFile)
    }
}
