import Foundation

/// Where a feed is in its load cycle.
///
/// Deliberately not generic over the loaded value: the store holds articles in
/// a separate property, so a refresh that fails can leave the previous content
/// on screen while still surfacing the error. That matters more here than in
/// most apps — a section pulls from several sources at once, and one dead feed
/// should never blank the four that are fine.
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
