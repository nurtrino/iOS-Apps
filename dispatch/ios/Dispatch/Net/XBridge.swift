import Foundation

/// How X posts get into the app.
///
/// This needs saying plainly, because it shapes the whole feature: **X has no
/// free public read API.** Reading a timeline needs either a paid API tier or a
/// server that reads on your behalf and republishes as RSS. There is no third
/// option, and no amount of client-side cleverness produces one.
///
/// So the app supports the bridges people actually run — Nitter and RSSHub —
/// and treats the bridge as configuration rather than pretending it is not
/// there. Both are commonly self-hosted, and a self-hosted instance is the only
/// arrangement that stays up, because the public ones are rate limited into
/// uselessness within weeks of being listed anywhere.
///
/// With no bridge set, X sources fall back to the publisher's own RSS. For
/// ZeroHedge that is the same newsroom, so the Wire section is genuinely
/// useful out of the box; it is simply the site feed rather than the timeline.
enum XBridgeKind: String, Codable, CaseIterable, Identifiable {
    case none
    case nitter
    case rsshub
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .nitter: return "Nitter"
        case .rsshub: return "RSSHub"
        case .custom: return "Custom URL"
        }
    }

    var detail: String {
        switch self {
        case .none:
            return "X sources fall back to the publisher's own RSS feed."
        case .nitter:
            return "A Nitter instance. Feeds are read from /<handle>/rss."
        case .rsshub:
            return "An RSSHub instance. Feeds are read from /twitter/user/<handle>."
        case .custom:
            return "Any URL containing {handle}, which is replaced per source."
        }
    }

    var hostPlaceholder: String {
        switch self {
        case .nitter: return "https://nitter.example.com"
        case .rsshub: return "https://rsshub.example.com"
        default: return "https://…"
        }
    }
}

struct XBridge: Codable, Equatable {

    var kind: XBridgeKind = .none
    /// Base URL of the instance, for `.nitter` and `.rsshub`.
    var host: String = ""
    /// Full URL template containing `{handle}`, for `.custom`.
    var template: String = ""

    static let handleToken = "{handle}"

    var isConfigured: Bool {
        switch kind {
        case .none: return false
        case .custom: return template.contains(XBridge.handleToken)
        case .nitter, .rsshub: return !normalizedHost.isEmpty
        }
    }

    /// The feed URL for one handle, or nil when no bridge can produce one.
    func feedURL(handle rawHandle: String) -> URL? {
        let handle = XBridge.normalizeHandle(rawHandle)
        guard !handle.isEmpty else { return nil }

        switch kind {
        case .none:
            return nil
        case .custom:
            guard template.contains(XBridge.handleToken) else { return nil }
            return URL(string: template.replacingOccurrences(of: XBridge.handleToken, with: handle))
        case .nitter:
            guard !normalizedHost.isEmpty else { return nil }
            return URL(string: "\(normalizedHost)/\(handle)/rss")
        case .rsshub:
            guard !normalizedHost.isEmpty else { return nil }
            return URL(string: "\(normalizedHost)/twitter/user/\(handle)")
        }
    }

    /// The host with a scheme and without a trailing slash, so a pasted
    /// "nitter.net/" and "https://nitter.net" build the same URL.
    ///
    /// An explicit scheme is always kept. When there is none, the guess depends
    /// on where the host lives: a self-hosted bridge on the LAN is nearly
    /// always plain http on a port, and defaulting those to https produces a
    /// TLS failure that reads like the bridge being down. Anything on the
    /// public internet defaults to https, because it should.
    var normalizedHost: String {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        while text.hasSuffix("/") { text.removeLast() }

        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return text }
        return (XBridge.isLocalHost(text) ? "http://" : "https://") + text
    }

    /// Addresses `NSAllowsLocalNetworking` covers, which are exactly the ones
    /// that can be reached over cleartext.
    static func isLocalHost(_ hostText: String) -> Bool {
        // Strip any port before testing, or "192.168.1.5:1200" never matches.
        let bare = hostText.split(separator: ":").first.map(String.init)?.lowercased() ?? ""

        if bare == "localhost" || bare.hasSuffix(".local") { return true }
        if bare.hasPrefix("192.168.") || bare.hasPrefix("10.") { return true }
        if bare.hasPrefix("127.") { return true }

        // 172.16.0.0/12 is 172.16 through 172.31, not all of 172.
        if bare.hasPrefix("172.") {
            let parts = bare.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// Accepts `@name`, `name`, or any x.com/twitter.com profile URL.
    static func normalizeHandle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        for prefix in ["x.com/", "twitter.com/", "mobile.twitter.com/", "nitter.net/"]
        where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("@") { text.removeFirst() }

        if let slash = text.firstIndex(of: "/") { text = String(text[text.startIndex..<slash]) }
        if let question = text.firstIndex(of: "?") { text = String(text[text.startIndex..<question]) }

        // Stop at the first character a handle cannot contain, rather than
        // filtering them out. Filtering turns a typo like "@bad handle" into
        // "badhandle" — a different account that may well exist.
        return String(text.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func profileURL(handle: String) -> URL? {
        let normalized = normalizeHandle(handle)
        guard !normalized.isEmpty else { return nil }
        return URL(string: "https://x.com/\(normalized)")
    }
}
