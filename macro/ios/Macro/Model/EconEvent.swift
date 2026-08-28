import Foundation

/// Forex Factory's impact scale, plus the values it uses for non-releases.
enum Impact: String, CaseIterable, Codable, Comparable {
    case holiday
    case low
    case medium
    case high

    /// FF writes "High"/"Medium"/"Low"/"Holiday"; anything unrecognised is
    /// treated as low rather than dropped, so a new label they invent still
    /// shows up.
    init(label: String) {
        switch label.lowercased() {
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        case "holiday", "non-economic": self = .holiday
        default: self = .low
        }
    }

    private var rank: Int {
        switch self {
        case .holiday: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (lhs: Impact, rhs: Impact) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .holiday: return "Holiday"
        }
    }
}

/// One row of the economic calendar.
struct EconEvent: Identifiable, Hashable {
    let id: String
    let title: String
    /// FF's "country" field is actually a currency code — USD, EUR, ALL.
    let currency: String
    let date: Date
    let impact: Impact
    let forecast: String?
    let previous: String?

    var isPast: Bool { date < Date() }

    var isToday: Bool {
        Calendar.autoupdatingCurrent.isDateInToday(date)
    }
}
