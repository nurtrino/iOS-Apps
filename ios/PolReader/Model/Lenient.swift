import Foundation

/// 4chan's JSON omits keys entirely for absent values, sends integers where
/// booleans are meant (`0`/`1`), and occasionally sends a string where the
/// documentation promises a number. Decoding must survive all of that: a single
/// unexpected field should never take down an entire post, because one bad post
/// in a 400-post thread would otherwise blank the whole screen.
///
/// Every field except the post number is read through these helpers.
extension KeyedDecodingContainer {

    /// A string, or `nil` if the key is missing, null, or of another type.
    /// A number is accepted and stringified, which covers fields the site has
    /// historically flip-flopped on (`trip` and `id` have both appeared as
    /// bare numbers for numeric-looking values).
    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    /// A string that is discarded when empty, so callers can use `nil` to mean
    /// "nothing to show" without checking for `""` everywhere.
    func lenientNonEmptyString(_ key: Key) -> String? {
        guard let value = lenientString(key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An integer, accepting a numeric string as well.
    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    /// 4chan encodes every boolean as `0` / `1`, and omits the key entirely
    /// rather than sending `0` in most cases. Absent therefore means false.
    func lenientFlag(_ key: Key) -> Bool {
        if let value = lenientInt(key) { return value != 0 }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        return false
    }

    /// A UNIX timestamp as a `Date`. Zero and negative values are treated as
    /// absent — the site uses `0` for "never archived".
    func lenientDate(_ key: Key) -> Date? {
        guard let seconds = lenientInt(key), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
