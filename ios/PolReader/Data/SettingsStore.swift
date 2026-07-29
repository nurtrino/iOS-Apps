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

/// How post images are presented.
///
/// /pol/ is flagged not-worksafe by the API (`ws_board: 0`) and is unmoderated
/// enough that images are frequently graphic. Blurring by default is the honest
/// setting for a board like this; it is a tap to reveal, and a switch to change.
enum ThumbnailMode: String, CaseIterable, Identifiable {
    case show, blur, hide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: return "Show"
        case .blur: return "Blur until tapped"
        case .hide: return "Hide entirely"
        }
    }
}

/// Chronological is the board's own shape and the default. Threaded is derived
/// from quotelinks and is genuinely useful on long argument chains.
enum ThreadViewMode: String, CaseIterable, Identifiable {
    case chronological, threaded
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chronological: return "Chronological"
        case .threaded: return "Threaded"
        }
    }
}

enum CatalogLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }
}

/// Auto-refresh cadence for an open thread.
///
/// The API documentation asks that thread updating be "set to a minimum of 10
/// seconds, preferably higher", so 10s is the floor offered and 30s the default.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60
    case fiveMinutes = 300

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .tenSeconds: return "10 seconds"
        case .thirtySeconds: return "30 seconds"
        case .sixtySeconds: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        }
    }
}

/// Persisted preferences.
///
/// Backed by `UserDefaults` read into `@Published` properties rather than
/// `@AppStorage`: `@AppStorage` does not publish its changes when it lives
/// inside an `ObservableObject`, so views observing this object would silently
/// fail to update. The `didSet` observers do not fire during `init`, which is
/// exactly what is wanted — loading persisted values costs no redundant writes.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    private enum Key {
        static let theme = "settings.theme"
        static let textScale = "settings.textScale"
        static let thumbnailMode = "settings.thumbnailMode"
        static let revealSpoilers = "settings.revealSpoilers"
        static let threadViewMode = "settings.threadViewMode"
        static let catalogLayout = "settings.catalogLayout"
        static let refreshInterval = "settings.refreshInterval"
        static let useInAppBrowser = "settings.useInAppBrowser"
        static let showCountryFlags = "settings.showCountryFlags"
        static let showPosterIDs = "settings.showPosterIDs"
        static let markThreadsRead = "settings.markThreadsRead"
        static let autoCollapseDepth = "settings.autoCollapseDepth"
        static let hasSeenContentNotice = "settings.hasSeenContentNotice"
    }

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    /// Multiplier applied to body text, 0.85...1.5.
    @Published var textScale: Double {
        didSet { defaults.set(textScale, forKey: Key.textScale) }
    }

    @Published var thumbnailMode: ThumbnailMode {
        didSet { defaults.set(thumbnailMode.rawValue, forKey: Key.thumbnailMode) }
    }

    @Published var revealSpoilersAutomatically: Bool {
        didSet { defaults.set(revealSpoilersAutomatically, forKey: Key.revealSpoilers) }
    }

    @Published var threadViewMode: ThreadViewMode {
        didSet { defaults.set(threadViewMode.rawValue, forKey: Key.threadViewMode) }
    }

    @Published var catalogLayout: CatalogLayout {
        didSet { defaults.set(catalogLayout.rawValue, forKey: Key.catalogLayout) }
    }

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval) }
    }

    @Published var useInAppBrowser: Bool {
        didSet { defaults.set(useInAppBrowser, forKey: Key.useInAppBrowser) }
    }

    @Published var showCountryFlags: Bool {
        didSet { defaults.set(showCountryFlags, forKey: Key.showCountryFlags) }
    }

    @Published var showPosterIDs: Bool {
        didSet { defaults.set(showPosterIDs, forKey: Key.showPosterIDs) }
    }

    @Published var markThreadsRead: Bool {
        didSet { defaults.set(markThreadsRead, forKey: Key.markThreadsRead) }
    }

    /// Replies nested deeper than this start collapsed in threaded mode.
    /// Zero disables auto-collapse.
    @Published var autoCollapseDepth: Int {
        didSet { defaults.set(autoCollapseDepth, forKey: Key.autoCollapseDepth) }
    }

    @Published var hasSeenContentNotice: Bool {
        didSet { defaults.set(hasSeenContentNotice, forKey: Key.hasSeenContentNotice) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        let storedScale = defaults.double(forKey: Key.textScale)
        textScale = storedScale > 0 ? storedScale : 1.0
        thumbnailMode = ThumbnailMode(rawValue: defaults.string(forKey: Key.thumbnailMode) ?? "") ?? .blur
        revealSpoilersAutomatically = defaults.bool(forKey: Key.revealSpoilers)
        threadViewMode = ThreadViewMode(rawValue: defaults.string(forKey: Key.threadViewMode) ?? "") ?? .chronological
        catalogLayout = CatalogLayout(rawValue: defaults.string(forKey: Key.catalogLayout) ?? "") ?? .grid
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: Key.refreshInterval)) ?? .thirtySeconds
        useInAppBrowser = defaults.object(forKey: Key.useInAppBrowser) as? Bool ?? true
        showCountryFlags = defaults.object(forKey: Key.showCountryFlags) as? Bool ?? true
        showPosterIDs = defaults.object(forKey: Key.showPosterIDs) as? Bool ?? true
        markThreadsRead = defaults.object(forKey: Key.markThreadsRead) as? Bool ?? true
        autoCollapseDepth = defaults.object(forKey: Key.autoCollapseDepth) as? Int ?? 0
        hasSeenContentNotice = defaults.bool(forKey: Key.hasSeenContentNotice)
    }

    /// A fresh store bound to throwaway defaults, for previews.
    static func preview() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard)
    }
}
