import Foundation

/// ISO 8601 period parsing, for `contentDetails.duration`.
///
/// The API documents the format as `PT#M#S`, which understates it: hour-long
/// videos carry an `H`, and archived multi-day livestreams carry a `D`. A
/// parser that only knows minutes and seconds returns nothing for those, which
/// surfaces as a video with no length rather than as an error anybody notices.
///
/// Transliterated from `vela/tools/duration_reference.py`, where the 29 cases
/// covering every shape the API emits are proven.
enum ISO8601Duration {

    /// Returns nil rather than zero for malformed input: live streams report a
    /// genuine `PT0S`, and a parse failure has to stay distinguishable from it.
    static func seconds(from text: String?) -> Int? {
        guard let text, text.first == "P" else { return nil }

        var total = 0
        var number = ""
        var inTime = false
        var sawComponent = false

        for character in text.dropFirst() {
            if character == "T" {
                // A second T, or a dangling number before it, is malformed.
                if inTime || !number.isEmpty { return nil }
                inTime = true
                continue
            }

            if character.isNumber {
                number.append(character)
                continue
            }

            guard let value = Int(number) else { return nil }
            number = ""
            sawComponent = true

            if inTime {
                switch character {
                case "H": total += value * 3600
                case "M": total += value * 60
                case "S": total += value
                default: return nil
                }
            } else {
                switch character {
                case "D": total += value * 86_400
                case "W": total += value * 604_800
                // Years and months have no fixed length. Rejected rather than
                // guessed at — inventing 30 days puts a silent lie on screen.
                default: return nil
                }
            }
        }

        // A trailing number with no unit ("PT4M13") is malformed.
        guard number.isEmpty, sawComponent else { return nil }
        return total
    }

    /// The label on a thumbnail. Hours appear only when there are hours, and
    /// minutes are padded only when an hour component precedes them — 9:05, but
    /// 1:09:05.
    static func label(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
