import Foundation

/// A PeerTube server.
///
/// The whole network is federated, so there is no single "the server" — the
/// instance is a runtime choice the reader makes and can change. Every relative
/// path the API returns (thumbnails, avatars, previews) is relative to whichever
/// instance answered, which is why URL building lives here rather than being
/// scattered through the views.
struct Instance: Hashable, Codable, Identifiable {

    /// Bare host, no scheme and no trailing slash: `makertube.net`.
    let host: String

    var id: String { host }

    var baseURL: URL? {
        URL(string: "https://\(host)")
    }

    var displayName: String { host }

    init(host: String) {
        // Accept whatever someone types — a full URL, a trailing slash, stray
        // whitespace — and reduce it to the bare host.
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        while cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        if let slash = cleaned.firstIndex(of: "/") { cleaned = String(cleaned[..<slash]) }
        self.host = cleaned
    }

    var isPlausible: Bool {
        // Not validation so much as a cheap guard against obvious typos before
        // spending a request on it.
        host.contains(".") && !host.contains(" ") && baseURL != nil
    }

    /// Resolve a path the API returned.
    ///
    /// Media URLs come back absolute (they may point at a redundancy server on
    /// another host entirely), while image paths come back relative. Both go
    /// through here so callers never have to know which they were handed.
    func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard let baseURL else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    func apiURL(_ endpoint: String, query: [URLQueryItem] = []) -> URL? {
        guard let baseURL else { return nil }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1").appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url
    }

    /// A handful of well-known public instances, purely as a starting point —
    /// anyone can type their own, and that is the normal case on a federated
    /// network.
    static let suggestions: [Instance] = [
        Instance(host: "makertube.net"),
        Instance(host: "tilvids.com"),
        Instance(host: "video.blender.org"),
        Instance(host: "framatube.org"),
        Instance(host: "diode.zone"),
    ]

    static let fallback = Instance(host: "makertube.net")
}

/// The subset of `/config` worth reading: what to call the place, and whether
/// signing up or signing in is even offered.
struct InstanceConfig: Hashable, Decodable {
    let name: String?
    let shortDescription: String?
    let signupAllowed: Bool

    private enum CodingKeys: String, CodingKey {
        case instance, signup
    }

    private enum InstanceKeys: String, CodingKey {
        case name, shortDescription
    }

    private enum SignupKeys: String, CodingKey {
        case allowed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let instance = try? c.nestedContainer(keyedBy: InstanceKeys.self, forKey: .instance)
        name = instance?.lenientNonEmptyString(.name)
        shortDescription = instance?.lenientNonEmptyString(.shortDescription)
        let signup = try? c.nestedContainer(keyedBy: SignupKeys.self, forKey: .signup)
        signupAllowed = signup?.lenientBool(.allowed) ?? false
    }
}
