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

/// Preferred download rendition. Resolution is a real choice here — the gap
/// between 1080p and 480p is routinely several hundred megabytes.
enum DownloadQuality: String, CaseIterable, Identifiable {
    case best, high, medium, low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Best available"
        case .high: return "Up to 1080p"
        case .medium: return "Up to 720p"
        case .low: return "Up to 480p"
        }
    }

    var ceiling: Int {
        switch self {
        case .best: return .max
        case .high: return 1080
        case .medium: return 720
        case .low: return 480
        }
    }

    /// Largest rendition at or under the ceiling, falling back to the smallest
    /// available when everything exceeds it.
    func pick(from files: [VideoFile]) -> VideoFile? {
        let playable = files.filter { !$0.isAudioOnly }
        let candidates = playable.isEmpty ? files : playable
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { $0.resolution > $1.resolution }
        return sorted.first { $0.resolution <= ceiling } ?? sorted.last
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

    static let shared = SettingsStore()

    private enum Key {
        static let theme = "settings.theme"
        static let downloadQuality = "settings.downloadQuality"
        static let downloadOnWiFiOnly = "settings.downloadOnWiFiOnly"
        static let includeNSFW = "settings.includeNSFW"
        static let autoplayNext = "settings.autoplayNext"
        static let defaultSort = "settings.defaultSort"
        static let trendingRegion = "settings.trendingRegion"
    }

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    @Published var downloadQuality: DownloadQuality {
        didSet { defaults.set(downloadQuality.rawValue, forKey: Key.downloadQuality) }
    }

    @Published var downloadOnWiFiOnly: Bool {
        didSet { defaults.set(downloadOnWiFiOnly, forKey: Key.downloadOnWiFiOnly) }
    }

    @Published var includeNSFW: Bool {
        didSet { defaults.set(includeNSFW, forKey: Key.includeNSFW) }
    }

    @Published var autoplayNext: Bool {
        didSet { defaults.set(autoplayNext, forKey: Key.autoplayNext) }
    }

    @Published var defaultSort: VideoSort {
        didSet { defaults.set(defaultSort.rawValue, forKey: Key.defaultSort) }
    }

    /// Which country's trending chart to show. YouTube's chart is per-region
    /// and the endpoint requires the code, so there is no "everywhere" option
    /// to fall back on.
    @Published var trendingRegion: String {
        didSet { defaults.set(trendingRegion, forKey: Key.trendingRegion) }
    }

    // See AuthStore: constructed only from the @MainActor App.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .dark
        downloadQuality = DownloadQuality(
            rawValue: defaults.string(forKey: Key.downloadQuality) ?? ""
        ) ?? .high
        downloadOnWiFiOnly = defaults.object(forKey: Key.downloadOnWiFiOnly) as? Bool ?? true
        includeNSFW = defaults.bool(forKey: Key.includeNSFW)
        autoplayNext = defaults.object(forKey: Key.autoplayNext) as? Bool ?? false
        defaultSort = VideoSort(
            rawValue: defaults.string(forKey: Key.defaultSort) ?? ""
        ) ?? .trending
        // Falls back to the device's own region rather than a hardcoded US,
        // which would show the wrong chart to most people.
        trendingRegion = defaults.string(forKey: Key.trendingRegion)
            ?? Locale.current.region?.identifier
            ?? "US"
    }
}
