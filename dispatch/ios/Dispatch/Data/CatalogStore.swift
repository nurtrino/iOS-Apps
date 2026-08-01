import Foundation

/// The sources, as edited.
///
/// The built-in catalog is a *default*, not a fixture: every field of every
/// built-in source can be changed, and the change persists. What cannot happen
/// is deleting a built-in outright — it is disabled instead — so a bad edit is
/// always one "Reset to default" away from working again, and the app never
/// reaches a state where the only way back is deleting it from the phone.
@MainActor
final class CatalogStore: ObservableObject {

    @Published private(set) var sources: [Source]

    private let sourcesFile = "sources"
    private let revisionFile = "catalog-revision"

    init(load: Bool = true) {
        guard load else {
            sources = SourceCatalog.defaults
            return
        }
        let stored = DiskStore.load([Source].self, from: sourcesFile)
        let merged = CatalogStore.merge(stored: stored, defaults: SourceCatalog.defaults)

        let storedRevision = DiskStore.load([Int].self, from: revisionFile)?.first ?? 1
        let migrated = CatalogStore.migrate(merged.sources, from: storedRevision)
        sources = migrated.sources

        // Retiring a built-in has to reach disk, or it is undone by whatever
        // writes next. Counting is not enough to detect it — a retirement and
        // an addition in the same release cancel out — so `merge` reports it.
        if merged.didRetire || migrated.didChange || storedRevision != SourceCatalog.behaviourRevision {
            persist()
            DiskStore.save([SourceCatalog.behaviourRevision], to: revisionFile)
        }
    }

    /// Resets flags whose meaning changed under a stored value.
    ///
    /// Only built-ins, and only the flags named here — this is not a general
    /// "reset everything", which would throw away real edits. See
    /// `SourceCatalog.behaviourRevision` for why a changed default is not enough.
    static func migrate(_ sources: [Source], from revision: Int) -> (sources: [Source], didChange: Bool) {
        guard revision < SourceCatalog.behaviourRevision else { return (sources, false) }

        var changed = false
        let updated = sources.map { source -> Source in
            guard source.isBuiltIn,
                  let shipped = SourceCatalog.default(withID: source.id) else { return source }
            var source = source

            // Rev < 2: `dropsUnsortable` changed meaning; reset it to shipped.
            if revision < 2, source.dropsUnsortable != shipped.dropsUnsortable {
                source.dropsUnsortable = shipped.dropsUnsortable
                changed = true
            }

            // Rev < 3: CFP moved from classified to fixed politics. Reset the
            // filing fields to shipped so the stored classified copy stops
            // splitting it across three sections. Scoped to CFP by id — this is
            // not a blanket "reset how every source files", which would throw
            // away deliberate edits to other outlets.
            if revision < 3, source.id == "citizenfreepress",
               source.topicMode != shipped.topicMode || source.fixedTopic != shipped.fixedTopic {
                source.topicMode = shipped.topicMode
                source.fixedTopic = shipped.fixedTopic
                source.topicPrior = shipped.topicPrior
                changed = true
            }

            return source
        }
        return (updated, changed)
    }

    /// Stored order wins; built-ins the stored copy has never seen are appended.
    ///
    /// The append is what lets a later version ship a new source and have it
    /// appear for someone who already has a catalog on disk. Without it, new
    /// built-ins are invisible to every existing install — the classic way a
    /// feature ships to nobody.
    private static func merge(stored: [Source]?,
                              defaults: [Source]) -> (sources: [Source], didRetire: Bool) {
        guard let stored, !stored.isEmpty else { return (defaults, false) }

        // Built-ins that no longer ship are dropped. Merging otherwise only
        // ever adds, so a retired source would live forever on a device that
        // already had it — which is the entire population the removal is for.
        let surviving = stored.filter { source in
            guard SourceCatalog.retired.contains(source.id) else { return true }
            FeedCache.delete(sourceID: source.id)
            return false
        }

        let known = Set(surviving.map(\.id))
        let additions = defaults.filter { $0.isBuiltIn && !known.contains($0.id) }
        return (surviving + additions, surviving.count != stored.count)
    }

    // MARK: - Queries

    var enabledSources: [Source] {
        sources.filter(\.isEnabled)
    }

    func source(id: String) -> Source? {
        sources.first { $0.id == id }
    }

    /// Sources that can put a story into this topic.
    ///
    /// A `.classified` source counts towards every topic it might reach, since
    /// whether it actually did is a per-article question the classifier answers
    /// later. This is what a refresh iterates, so it has to over-include rather
    /// than under-include.
    func sources(reaching topic: Topic, includeDisabled: Bool = false) -> [Source] {
        sources.filter { source in
            guard includeDisabled || source.isEnabled else { return false }
            return source.reachableTopics.contains(topic)
        }
    }

    /// Sources filed under a topic for the *management* screen — where a
    /// `.classified` source appears once, under its fallback, rather than three
    /// times.
    func sourcesFiled(under topic: Topic, includeDisabled: Bool = true) -> [Source] {
        sources.filter { source in
            guard includeDisabled || source.isEnabled else { return false }
            return source.fixedTopic == topic
        }
    }

    // MARK: - Mutation

    func update(_ source: Source) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        persist()
    }

    func setEnabled(_ enabled: Bool, forSourceID id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        persist()
    }

    func add(_ source: Source) {
        var candidate = source
        candidate.id = uniqueID(basedOn: source.id.isEmpty ? source.name : source.id)
        candidate.isBuiltIn = false
        sources.append(candidate)
        persist()
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
        persist()
    }

    func resetToDefault(sourceID: String) {
        guard let fresh = SourceCatalog.default(withID: sourceID),
              let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index] = fresh
        persist()
    }

    func moveSources(filedUnder topic: Topic, from offsets: IndexSet, to destination: Int) {
        // The rows being reordered are a filtered view of `sources`, so the
        // move is applied to that slice and written back by identity. Applying
        // the offsets to the full array directly would move the wrong rows the
        // moment any source belongs to another topic.
        var slice = sourcesFiled(under: topic)
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
        persist()
    }

    func resetEverything() {
        sources = SourceCatalog.defaults
        persist()
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

    private func persist() {
        DiskStore.save(sources, to: sourcesFile)
    }
}
