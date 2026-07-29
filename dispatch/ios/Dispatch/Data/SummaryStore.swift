import Foundation

/// The generated briefs, one per topic, and the discipline around regenerating
/// them.
///
/// The discipline is the point of the class. Every API call here costs real
/// money on somebody's key, and the wire sources produce a new post every few
/// minutes — naively summarizing "whenever the headlines change" would burn a
/// request per refresh all day. So a brief regenerates only when both are true:
/// the set of headlines actually changed, and the last generation is at least a
/// few minutes old. Between those, the cached text stands; slightly stale prose
/// over five fresh headlines beats an invoice.
@MainActor
final class SummaryStore: ObservableObject {

    struct GeneratedBrief: Codable, Equatable {
        var text: String
        /// Hash of the article ids the text was written from — the "has the
        /// input changed" question answered without keeping the input.
        var inputKey: String
        var generated: Date
    }

    /// Keyed by `Topic.rawValue` so the dictionary encodes as a plain JSON
    /// object.
    @Published private(set) var briefs: [String: GeneratedBrief]
    @Published private(set) var working: Set<String> = []
    /// The last failure per topic, for the section to mention when it has no
    /// cached text to show instead.
    @Published private(set) var failures: [String: String] = [:]

    private static let fileName = "briefs"

    /// How fresh a brief must be before a changed headline set is allowed to
    /// trigger another request.
    static let minimumInterval: TimeInterval = 5 * 60

    init() {
        briefs = DiskStore.load([String: GeneratedBrief].self, from: SummaryStore.fileName) ?? [:]
    }

    /// One deterministic name for a set of articles, order-independent —
    /// a refresh that reorders the same five headlines is not a change.
    ///
    /// The model and prompt revision are part of it because the text depends on
    /// them as much as on the headlines: switching models has to produce a new
    /// brief, not leave the old model's prose in place indefinitely. Mirrored in
    /// `tools/feed_reference.py`.
    static func inputKey(for articles: [Article]) -> String {
        let prefix = "\(SummaryAPI.model)#\(SummaryAPI.promptRevision)"
        return StableHash.hex(([prefix] + articles.map(\.id).sorted()).joined(separator: "\n"))
    }

    func brief(for topic: Topic) -> GeneratedBrief? {
        briefs[topic.rawValue]
    }

    func failure(for topic: Topic) -> String? {
        failures[topic.rawValue]
    }

    /// Regenerates a topic's brief if the input changed and the cooldown has
    /// passed. Safe to call on every appearance; almost every call returns
    /// without a request.
    func refreshIfNeeded(topic: Topic, articles: [Article], headlines: [SummaryAPI.Headline]) async {
        guard !articles.isEmpty, !headlines.isEmpty else { return }
        guard !working.contains(topic.rawValue) else { return }

        let key = SummaryStore.inputKey(for: articles)
        if let existing = briefs[topic.rawValue] {
            if existing.inputKey == key { return }
            if Date().timeIntervalSince(existing.generated) < SummaryStore.minimumInterval { return }
        }

        guard let apiKey = await AnthropicKeychain.shared.load() else { return }

        working.insert(topic.rawValue)
        defer { working.remove(topic.rawValue) }

        do {
            let text = try await SummaryAPI.summarize(topic: topic.title, headlines: headlines, key: apiKey)
            briefs[topic.rawValue] = GeneratedBrief(text: text, inputKey: key, generated: Date())
            failures[topic.rawValue] = nil
            DiskStore.save(briefs, to: SummaryStore.fileName)
        } catch {
            // The old text, if any, stays on screen. The failure is recorded
            // so the section can say why there is nothing, when there is
            // nothing.
            failures[topic.rawValue] = (error as? SummaryAPI.SummaryError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func clearAll() {
        briefs = [:]
        failures = [:]
        DiskStore.delete(SummaryStore.fileName)
    }
}
