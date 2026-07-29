import Foundation

/// Where a screen is in its load cycle.
///
/// Deliberately not generic over the loaded value: stores hold their data in a
/// separate published property, so a refresh that fails can leave the previous
/// content on screen while still surfacing the error. Bundling the value into
/// the phase forces a choice between showing stale content and showing the
/// error, and the honest answer is usually both.
enum LoadPhase: Equatable {
    /// Nothing requested yet.
    case idle
    /// First load, nothing to show behind it.
    case loading
    /// A reload on top of content that is already on screen.
    case refreshing
    case loaded
    /// Carries the one user-facing sentence decided in the network layer.
    case failed(String)

    var isBusy: Bool {
        self == .loading || self == .refreshing
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// True when the screen has nothing to render and is not about to.
    func isEmptyState(hasContent: Bool) -> Bool {
        !hasContent && (self == .loaded || self == .idle)
    }
}
