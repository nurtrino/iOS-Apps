import Foundation

/// The UserDefaults keys, in one place, because two things read them: the
/// observable store the UI binds to, and the plain snapshot the background
/// refresh loads with no UI alive.
enum SettingsKeys {
    static let enabledSources = "enabledSources"
    static let headlineAlerts = "headlineAlerts"
    static let eventAlertLevel = "eventAlertLevel"
    static let eventLeadMinutes = "eventLeadMinutes"
    static let alertCurrenciesOnly = "alertCurrenciesOnly"
}

/// Which calendar events deserve a notification.
enum EventAlertLevel: String, CaseIterable, Identifiable {
    case off
    case high
    case highAndMedium

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .high: return "High impact"
        case .highAndMedium: return "High + medium"
        }
    }

    var impacts: Set<Impact> {
        switch self {
        case .off: return []
        case .high: return [.high]
        case .highAndMedium: return [.high, .medium]
        }
    }
}

/// A plain value copy of the settings, readable from any context.
///
/// The background refresh launches with no UI and must not touch main-actor
/// stores; everything it needs is on disk already.
struct SettingsSnapshot {
    var enabledSources: Set<String>
    var headlineAlerts: Bool
    var eventAlertLevel: EventAlertLevel
    var eventLeadMinutes: Int
    /// Restrict event alerts to the majors someone actually trades. Empty
    /// means all currencies.
    var alertCurrenciesOnly: Set<String>

    static func load(_ defaults: UserDefaults = .standard) -> SettingsSnapshot {
        let sources: Set<String>
        if let stored = defaults.array(forKey: SettingsKeys.enabledSources) as? [String] {
            sources = Set(stored).intersection(FeedCatalog.allIDs)
        } else {
            // No stored value means a fresh install: everything on.
            sources = FeedCatalog.allIDs
        }

        return SettingsSnapshot(
            enabledSources: sources,
            headlineAlerts: defaults.object(forKey: SettingsKeys.headlineAlerts) as? Bool ?? false,
            eventAlertLevel: EventAlertLevel(
                rawValue: defaults.string(forKey: SettingsKeys.eventAlertLevel) ?? ""
            ) ?? .high,
            eventLeadMinutes: defaults.object(forKey: SettingsKeys.eventLeadMinutes) as? Int ?? 15,
            alertCurrenciesOnly: Set(
                defaults.array(forKey: SettingsKeys.alertCurrenciesOnly) as? [String] ?? []
            )
        )
    }
}

/// The observable store the UI binds to. Every write goes straight to
/// UserDefaults so the next `SettingsSnapshot.load()` — foreground or
/// background — sees it.
@MainActor
final class SettingsStore: ObservableObject {

    private let defaults = UserDefaults.standard

    @Published var enabledSources: Set<String> {
        didSet { defaults.set(Array(enabledSources).sorted(), forKey: SettingsKeys.enabledSources) }
    }

    @Published var headlineAlerts: Bool {
        didSet { defaults.set(headlineAlerts, forKey: SettingsKeys.headlineAlerts) }
    }

    @Published var eventAlertLevel: EventAlertLevel {
        didSet { defaults.set(eventAlertLevel.rawValue, forKey: SettingsKeys.eventAlertLevel) }
    }

    @Published var eventLeadMinutes: Int {
        didSet { defaults.set(eventLeadMinutes, forKey: SettingsKeys.eventLeadMinutes) }
    }

    @Published var alertCurrenciesOnly: Set<String> {
        didSet { defaults.set(Array(alertCurrenciesOnly).sorted(), forKey: SettingsKeys.alertCurrenciesOnly) }
    }

    init() {
        let snapshot = SettingsSnapshot.load()
        enabledSources = snapshot.enabledSources
        headlineAlerts = snapshot.headlineAlerts
        eventAlertLevel = snapshot.eventAlertLevel
        eventLeadMinutes = snapshot.eventLeadMinutes
        alertCurrenciesOnly = snapshot.alertCurrenciesOnly
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            enabledSources: enabledSources,
            headlineAlerts: headlineAlerts,
            eventAlertLevel: eventAlertLevel,
            eventLeadMinutes: eventLeadMinutes,
            alertCurrenciesOnly: alertCurrenciesOnly
        )
    }

    func isEnabled(_ source: FeedSource) -> Bool {
        enabledSources.contains(source.id)
    }

    func toggle(_ source: FeedSource, on: Bool) {
        if on {
            enabledSources.insert(source.id)
        } else {
            enabledSources.remove(source.id)
        }
    }
}
