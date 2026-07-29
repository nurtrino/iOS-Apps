import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// How long a cached feed stays good before opening the app refetches it.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case always = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case hourly = 60

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .always: return "Every time"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .thirtyMinutes: return "After 30 minutes"
        case .hourly: return "After an hour"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

/// Where a headline opens.
enum LinkBehavior: String, CaseIterable, Identifiable {
    /// The app's own reader, built from the feed's own body text.
    case reader
    /// Safari in a sheet, so the site's own layout and paywall apply.
    case safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reader: return "Reader"
        case .safari: return "Web page"
        }
    }
}

/// Persisted preferences.
///
/// `UserDefaults` read into `@Published` properties rather than `@AppStorage`:
/// `@AppStorage` does not publish its changes from inside an
/// `ObservableObject`, so observing views would silently fail to update. The
/// `didSet` observers do not fire during `init`, so loading costs no redundant
/// writes.
@MainActor
final class SettingsStore: ObservableObject {

    private enum Key {
        static let theme = "settings.theme"
        static let refreshInterval = "settings.refreshInterval"
        static let linkBehavior = "settings.linkBehavior"
        static let showImages = "settings.showImages"
        static let compactRows = "settings.compactRows"
        static let markReadOnOpen = "settings.markReadOnOpen"
        static let hideRead = "settings.hideRead"
        static let itemsPerSource = "settings.itemsPerSource"
        static let readerTextScale = "settings.readerTextScale"
        static let xBridge = "settings.xBridge"
        static let steamID = "settings.steamID"
        static let steamItemsPerGame = "settings.steamItemsPerGame"
        static let steamMaxGames = "settings.steamMaxGames"
        static let hasSteamKey = "settings.hasSteamKey"
    }

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval) }
    }

    @Published var linkBehavior: LinkBehavior {
        didSet { defaults.set(linkBehavior.rawValue, forKey: Key.linkBehavior) }
    }

    @Published var showImages: Bool {
        didSet { defaults.set(showImages, forKey: Key.showImages) }
    }

    @Published var compactRows: Bool {
        didSet { defaults.set(compactRows, forKey: Key.compactRows) }
    }

    @Published var markReadOnOpen: Bool {
        didSet { defaults.set(markReadOnOpen, forKey: Key.markReadOnOpen) }
    }

    @Published var hideRead: Bool {
        didSet { defaults.set(hideRead, forKey: Key.hideRead) }
    }

    @Published var itemsPerSource: Int {
        didSet { defaults.set(itemsPerSource, forKey: Key.itemsPerSource) }
    }

    /// Multiplier on the reader's body font, 0.8 to 1.6.
    @Published var readerTextScale: Double {
        didSet { defaults.set(readerTextScale, forKey: Key.readerTextScale) }
    }

    @Published var xBridge: XBridge {
        didSet {
            guard let data = try? JSONEncoder().encode(xBridge) else { return }
            defaults.set(data, forKey: Key.xBridge)
        }
    }

    @Published var steamID: String {
        didSet { defaults.set(steamID, forKey: Key.steamID) }
    }

    @Published var steamItemsPerGame: Int {
        didSet { defaults.set(steamItemsPerGame, forKey: Key.steamItemsPerGame) }
    }

    @Published var steamMaxGames: Int {
        didSet { defaults.set(steamMaxGames, forKey: Key.steamMaxGames) }
    }

    /// Mirrors whether a key is in the Keychain.
    ///
    /// The key itself never comes back out into a published property, but the
    /// Settings screen has to render "Key saved" versus "Add key" synchronously
    /// while a Keychain read is an actor hop away.
    @Published private(set) var hasSteamKey: Bool {
        didSet { defaults.set(hasSteamKey, forKey: Key.hasSteamKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        refreshInterval = RefreshInterval(rawValue: defaults.object(forKey: Key.refreshInterval) as? Int ?? 15)
            ?? .fifteenMinutes
        linkBehavior = LinkBehavior(rawValue: defaults.string(forKey: Key.linkBehavior) ?? "") ?? .reader
        showImages = defaults.object(forKey: Key.showImages) as? Bool ?? true
        compactRows = defaults.object(forKey: Key.compactRows) as? Bool ?? false
        markReadOnOpen = defaults.object(forKey: Key.markReadOnOpen) as? Bool ?? true
        hideRead = defaults.object(forKey: Key.hideRead) as? Bool ?? false
        itemsPerSource = defaults.object(forKey: Key.itemsPerSource) as? Int ?? 40
        readerTextScale = defaults.object(forKey: Key.readerTextScale) as? Double ?? 1.0
        steamID = defaults.string(forKey: Key.steamID) ?? ""
        steamItemsPerGame = defaults.object(forKey: Key.steamItemsPerGame) as? Int ?? 3
        steamMaxGames = defaults.object(forKey: Key.steamMaxGames) as? Int ?? 12
        hasSteamKey = defaults.bool(forKey: Key.hasSteamKey)

        if let data = defaults.data(forKey: Key.xBridge),
           let decoded = try? JSONDecoder().decode(XBridge.self, from: data) {
            xBridge = decoded
        } else {
            xBridge = XBridge()
        }
    }

    // MARK: - Steam key

    func saveSteamKey(_ key: String) async {
        await SteamKeychain.shared.save(key)
        hasSteamKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearSteamKey() async {
        await SteamKeychain.shared.clear()
        hasSteamKey = false
    }

    func steamKey() async -> String? {
        await SteamKeychain.shared.load()
    }

    /// The knobs a feed load needs, gathered in one place so `FeedStore` does
    /// not reach back into settings from a background task.
    func steamContext(games: [SteamGame]) -> SteamContext {
        SteamContext(games: games,
                     itemsPerGame: steamItemsPerGame,
                     maxGames: steamMaxGames)
    }
}
