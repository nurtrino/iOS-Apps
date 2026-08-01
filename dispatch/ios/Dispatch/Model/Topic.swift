import SwiftUI

/// The four parts of the app.
///
/// These are not filters over one feed — each is a screen of its own with its
/// own furniture. War has a live rail, Markets has charts and a release
/// calendar, Gaming has the Steam library. A story belongs to exactly one.
enum Topic: String, Codable, CaseIterable, Identifiable {
    case war
    case politics
    case economics
    case tech
    case gaming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .war: return "War"
        case .politics: return "Politics"
        case .economics: return "Markets"
        case .tech: return "Tech"
        case .gaming: return "Gaming"
        }
    }

    var systemImage: String {
        switch self {
        case .war: return "shield.lefthalf.filled"
        case .politics: return "building.columns"
        case .economics: return "chart.line.uptrend.xyaxis"
        case .tech: return "cpu"
        case .gaming: return "gamecontroller"
        }
    }

    /// The topics the classifier is allowed to choose between.
    ///
    /// Gaming and Tech are excluded deliberately. No general news source
    /// publishes into them — every gaming and every tech article comes from a
    /// source that only ever publishes that one thing — so letting the
    /// classifier pick them would only ever be a mistake. They are `.fixed`
    /// sources routed straight to their section.
    static let classifiable: [Topic] = [.war, .politics, .economics]
}

/// Per-topic colour, so each part of the app feels like a different place.
///
/// One accent each rather than the app's amber everywhere: the point of
/// splitting the sections up was that they are different kinds of reading, and
/// colour is the cheapest way to say which one you are in without a label.
enum TopicTheme {

    static func accent(_ topic: Topic) -> Color {
        switch topic {
        case .war: return Color(red: 0.847, green: 0.267, blue: 0.216)
        case .politics: return Color(red: 0.361, green: 0.541, blue: 0.831)
        case .economics: return Color(red: 0.243, green: 0.706, blue: 0.478)
        // A cyan that reads as "tech" and stays clear of the economics green
        // and the politics blue on either side of it.
        case .tech: return Color(red: 0.239, green: 0.729, blue: 0.792)
        case .gaming: return Color(red: 0.494, green: 0.443, blue: 0.878)
        }
    }

    static func deep(_ topic: Topic) -> Color {
        accent(topic).opacity(0.16)
    }

    /// A very low-contrast wash behind the section header.
    static func wash(_ topic: Topic) -> Color {
        accent(topic).opacity(0.08)
    }
}
