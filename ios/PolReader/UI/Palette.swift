import SwiftUI

/// Colours borrowed from the site's own conventions, adjusted for legibility on
/// both schemes. Greentext in particular has a canonical value (#789922) that
/// readers recognise instantly and that should not be invented.
enum Palette {

    static let greentext = Color(red: 0.47, green: 0.60, blue: 0.13)          // #789922
    static let greentextDark = Color(red: 0.55, green: 0.70, blue: 0.25)

    static let quotelink = Color(red: 0.37, green: 0.54, blue: 0.67)          // #5F89AC
    static let externalLink = Color(red: 0.20, green: 0.47, blue: 0.75)

    static let deadlink = Color(red: 0.80, green: 0.25, blue: 0.25)

    static let posterIDBackgroundAlpha = 0.85

    static let accent = Color(red: 0.55, green: 0.70, blue: 0.25)             // #8CB33F

    static func greentext(for scheme: ColorScheme) -> Color {
        scheme == .dark ? greentextDark : greentext
    }

    /// A stable colour for a per-thread poster ID.
    ///
    /// /pol/ assigns each poster an 8-character ID for the life of a thread.
    /// Colouring them is what makes "this is the same person again" visible at
    /// a glance, so the mapping has to be deterministic — the same ID must get
    /// the same colour on every launch and in every thread.
    static func posterIDColor(_ id: String) -> Color {
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        // Fixed saturation and brightness so every ID badge carries the same
        // visual weight regardless of which hue it landed on.
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}
