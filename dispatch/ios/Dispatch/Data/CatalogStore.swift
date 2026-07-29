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

    init(load: Bool = true) {
        guard load else {
            sources = SourceCatalog.defaults
            return
        }
        sources = CatalogStore.merge(stored: DiskStore.load([Source].self, from: sourcesFile),
                                     defaults: SourceCatalog.defaults)
    }

    /// Stored order wins; built-ins the stored copy has never seen are appended.
    ///
    /// The append is what lets a later version ship a new source and have it
    /// appear for someone who already has a catalog on disk. Without it, new
    /// built-ins are invisible to every existing install — the classic way a
    /// feature ships to nobody.
    private static func merge(stored: [Source]?, defaults: [Source]) -> [Source] {
        guard let stored, !stored.isEmpty else { return defaults }
        let known = Set(stored.map(\.id))
        return stored + defaults.filter { $0.isBuiltIn && !known.contains($0.id) }
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
