import Foundation

/// Makes a real-world feed well-formed enough for `XMLParser`.
///
/// This is the least glamorous file in the app and the one that decides whether
/// half the sources work. `XMLParser` is a strict, non-recovering parser: it
/// stops at the first error and hands back nothing. Feeds in the wild break its
/// rules constantly and browsers never complain, so publishers never find out:
///
/// - `&nbsp;`, `&mdash;`, `&rsquo;` — HTML entities, undefined in XML. Fatal.
/// - A bare `&` in "Q&A" or a query string. Fatal.
/// - Control characters that survived a copy-paste out of Word. Fatal.
/// - An `encoding="ISO-8859-1"` declaration on bytes we have already decoded,
///   which makes the parser decode them a second time into mojibake.
///
/// Every one of those is repaired here, before parsing, rather than discovering
/// downstream that a source "has no items today".
enum XMLSanitizer {

    /// Bytes to text.
    ///
    /// Lossy UTF-8 by default: a single bad byte in a 400 KB feed should cost
    /// one replacement character, not the entire document. The declared
    /// encoding is honoured only when it names a Latin-1 family charset, which
    /// is the one case where guessing UTF-8 would corrupt every accented
    /// character rather than just the bad byte.
    static func text(from data: Data) -> String {
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if prefix.contains("iso-8859-1") || prefix.contains("windows-1252")
            || prefix.contains("latin-1") || prefix.contains("latin1") {
            if let decoded = String(data: data, encoding: .isoLatin1) { return decoded }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func sanitizedData(from data: Data) -> Data {
        Data(sanitize(text(from: data)).utf8)
    }

    /// The repair pass.
    static func sanitize(_ raw: String) -> String {
        var text = raw

        // A BOM or any whitespace ahead of the declaration is "content before
        // the XML declaration" and fatal on its own.
        while let first = text.unicodeScalars.first,
              first == "\u{FEFF}" || CharacterSet.whitespacesAndNewlines.contains(first) {
            text.unicodeScalars.removeFirst()
        }

        text = rewriteDeclaredEncoding(in: text)
        return rewriteEntities(in: text)
    }

    /// The declaration describes the *bytes*, and by now they are UTF-8.
    ///
    /// Leaving `encoding="ISO-8859-1"` on a UTF-8 buffer is how "don’t" becomes
    /// "donâ€™t" — the source is fine, the parser is told to decode it twice.
    private static func rewriteDeclaredEncoding(in text: String) -> String {
        guard text.hasPrefix("<?xml") else { return text }
        guard let close = text.range(of: "?>") else { return text }

        let declaration = text[text.startIndex..<close.upperBound]
        guard declaration.range(of: "encoding", options: .caseInsensitive) != nil else { return text }

        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + text[close.upperBound...]
    }

    /// Rewrites every character reference XML does not define, and escapes
    /// every ampersand that was never a reference at all.
    static func rewriteEntities(in text: String) -> String {
        guard text.contains("&") || text.unicodeScalars.contains(where: isForbiddenControl) else {
            return text
        }

        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count + scalars.count / 8)

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]

            if isForbiddenControl(scalar) {
                // Not representable in XML 1.0 in any form, escaped or not.
                index += 1
                continue
            }

            guard scalar == "&" else {
                out.append(scalar)
                index += 1
                continue
            }

            guard let (name, next) = readEntityName(scalars, from: index) else {
                out.append(contentsOf: "&amp;".unicodeScalars)
                index += 1
                continue
            }

            if HTMLEntities.xmlBuiltIns.contains(name) {
                out.append(contentsOf: ("&" + name + ";").unicodeScalars)
                index = next
                continue
            }

            if name.hasPrefix("#") {
                // Numeric references are legal XML, but only if they name a
                // character XML allows. `&#12;` is neither.
                if let replacement = HTMLEntities.replacement(for: name),
                   let scalar = replacement.unicodeScalars.first,
                   !isForbiddenControl(scalar) {
                    out.append(contentsOf: ("&" + name + ";").unicodeScalars)
                }
                index = next
                continue
            }

            if let replacement = HTMLEntities.replacement(for: name) {
                for scalar in replacement.unicodeScalars where !isForbiddenControl(scalar) {
                    out.append(contentsOf: numericReference(for: scalar).unicodeScalars)
                }
                index = next
                continue
            }

            // Not a reference this app knows. Escaping the ampersand and
            // keeping the text is the lossless choice: the reader sees
            // "&foo;" rather than the feed failing to parse.
            out.append(contentsOf: "&amp;".unicodeScalars)
            index += 1
        }

        return String(out)
    }

    /// Reads `name` out of `&name;`, returning the index just past the `;`.
    ///
    /// The 34-scalar cap is what separates a reference from a bare ampersand
    /// followed by a semicolon somewhere later in the sentence.
    private static func readEntityName(_ scalars: [Unicode.Scalar],
                                       from start: Int) -> (name: String, next: Int)? {
        var cursor = start + 1
        let limit = min(scalars.count, start + 35)
        var name = String.UnicodeScalarView()

        while cursor < limit {
            let scalar = scalars[cursor]
            if scalar == ";" {
                guard !name.isEmpty else { return nil }
                return (String(name), cursor + 1)
            }
            let isNameCharacter = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "#" || scalar == "x" || scalar == "X"
            guard isNameCharacter else { return nil }
            name.append(scalar)
            cursor += 1
        }
        return nil
    }

    private static func numericReference(for scalar: Unicode.Scalar) -> String {
        "&#\(scalar.value);"
    }

    /// The characters XML 1.0 forbids outright.
    static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A || value == 0x0D { return false }
        if value < 0x20 { return true }
        if (0x7F...0x84).contains(value) || (0x86...0x9F).contains(value) { return true }
        if (0xD800...0xDFFF).contains(value) { return true }
        if value == 0xFFFE || value == 0xFFFF { return true }
        return false
    }
}
