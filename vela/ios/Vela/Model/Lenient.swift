import Foundation

/// PeerTube is federated: every instance runs its own version, and a client
/// talks to servers spanning several releases at once. Fields appear, change
/// shape and go away between them, and a video that fails to decode because one
/// instance omitted a key nobody reads is a blank screen for no reason.
///
/// So every field except the identifier is read leniently.
extension KeyedDecodingContainer {

    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    func lenientNonEmptyString(_ key: Key) -> String? {
        guard let value = lenientString(key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = lenientInt(key) { return value != 0 }
        return nil
    }

    /// Timestamps are ISO 8601, sometimes with fractional seconds and sometimes
    /// without, depending on the instance's version.
    func lenientDate(_ key: Key) -> Date? {
        guard let raw = lenientNonEmptyString(key) else { return nil }
        return ISO8601.parse(raw)
    }

    /// Several PeerTube fields are `{ id, label }` constants — category,
    /// licence, language, resolution, privacy. Only the label is ever shown.
    func lenientConstantLabel(_ key: Key) -> String? {
        guard let nested = try? nestedContainer(keyedBy: ConstantKey.self, forKey: key) else {
            return lenientNonEmptyString(key)
        }
        return nested.lenientNonEmptyString(.label)
    }

    func lenientConstantID(_ key: Key) -> Int? {
        guard let nested = try? nestedContainer(keyedBy: ConstantKey.self, forKey: key) else {
            return lenientInt(key)
        }
        return nested.lenientInt(.id)
    }
}

/// Keys of PeerTube's `{ id, label }` constant objects.
enum ConstantKey: String, CodingKey {
    case id, label
}

/// Parsing only, never formatting — nothing here writes a date back.
enum ISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        withFractional.date(from: raw) ?? plain.date(from: raw)
    }
}
