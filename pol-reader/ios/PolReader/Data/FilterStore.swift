import Foundation

/// Which part of a post a filter is tested against.
enum FilterField: String, Codable, CaseIterable, Identifiable {
    case comment, subject, name, posterID, filename, country

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comment: return "Comment"
        case .subject: return "Subject"
        case .name: return "Name / tripcode"
        case .posterID: return "Poster ID"
        case .filename: return "Filename"
        case .country: return "Country"
        }
    }
}

/// A rule that hides matching posts, and in the catalog, matching threads.
struct PostFilter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var pattern: String
    var field: FilterField = .comment
    var isRegex: Bool = false
    var isEnabled: Bool = true
}

/// User-defined filters.
///
/// A filter list is table stakes for a board like /pol/, where a handful of
/// recurring thread templates and copypasta dominate the catalog. Hiding a post
/// hides its replies too — see `Outline.filtered` — because leaving orphans
/// quoting something invisible reads as a bug.
@MainActor
final class FilterStore: ObservableObject {

    static let shared = FilterStore()

    private static let file = "filters"

    @Published private(set) var filters: [PostFilter] = [] {
        didSet { rebuild() }
    }

    /// Compiled once per change rather than per post. A thread runs to hundreds
    /// of posts and the filter list is checked against every one of them.
    private var compiled: [(filter: PostFilter, regex: NSRegularExpression?)] = []

    private let writer = DebouncedWriter()

    init(loadFromDisk: Bool = true) {
        if loadFromDisk {
            filters = DiskStore.load([PostFilter].self, from: Self.file) ?? []
        }
        rebuild()
    }

    var isEmpty: Bool { compiled.isEmpty }

    func add(_ filter: PostFilter) {
        filters.append(filter)
        persist()
    }

    func update(_ filter: PostFilter) {
        guard let index = filters.firstIndex(where: { $0.id == filter.id }) else { return }
        filters[index] = filter
        persist()
    }

    func remove(at offsets: IndexSet) {
        filters.remove(atOffsets: offsets)
        persist()
    }

    func remove(id: UUID) {
        filters.removeAll { $0.id == id }
        persist()
    }

    /// True when the post should be hidden.
    func hides(_ post: Post) -> Bool {
        guard !compiled.isEmpty else { return false }
        for entry in compiled {
            guard let haystack = value(of: entry.filter.field, in: post), !haystack.isEmpty else {
                continue
            }
            if matches(entry, haystack) { return true }
        }
        return false
    }

    /// True when the thread should be hidden from the catalog. Tested against
    /// the OP only — a thread is not hidden because one reply matched.
    func hides(_ thread: CatalogThread) -> Bool {
        hides(thread.op)
    }

    private func matches(_ entry: (filter: PostFilter, regex: NSRegularExpression?), _ haystack: String) -> Bool {
        if let regex = entry.regex {
            let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            return regex.firstMatch(in: haystack, options: [], range: range) != nil
        }
        return haystack.range(of: entry.filter.pattern, options: .caseInsensitive) != nil
    }

    /// The comment is matched against its **rendered text**, not its HTML, so a
    /// filter for "http" does not match every post that merely contains a link
    /// tag, and a filter never accidentally matches markup the reader cannot see.
    private func value(of field: FilterField, in post: Post) -> String? {
        switch field {
        case .comment:
            return renderedText(post.comment)
        case .subject:
            return post.subject
        case .name:
            return [post.name, post.trip].compactMap { $0 }.joined(separator: " ")
        case .posterID:
            return post.posterID
        case .filename:
            return post.attachment?.displayName
        case .country:
            return [post.country, post.countryName, post.boardFlag, post.flagName]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    private func renderedText(_ html: String?) -> String? {
        guard let html else { return nil }
        let blocks = CommentParserCache.shared.blocks(for: html)
        guard !blocks.isEmpty else { return nil }
        var parts: [String] = []
        for block in blocks {
            switch block {
            case .paragraph(let paragraph): parts.append(paragraph.text)
            case .code(let text): parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
    }

    private func rebuild() {
        compiled = filters.filter { $0.isEnabled && !$0.pattern.isEmpty }.map { filter in
            guard filter.isRegex else { return (filter, nil) }
            // An invalid pattern falls back to a literal match rather than
            // silently matching nothing while the reader believes it works.
            let regex = try? NSRegularExpression(pattern: filter.pattern, options: [.caseInsensitive])
            return (filter, regex)
        }
    }

    private func persist() {
        let snapshot = filters
        writer.schedule { DiskStore.save(snapshot, to: Self.file) }
    }

    func flush() { writer.flush() }
}
