import SwiftUI

/// A thread to open, optionally focused on a particular post.
struct ThreadRoute: Hashable {
    let board: String
    let no: Int
    var focusPost: Int?
}

/// Owns a tab's navigation path.
///
/// Held as an object rather than passed as a binding so that a quotelink tapped
/// several levels down inside a comment body can push a thread without every
/// intervening view having to forward a binding for it.
@MainActor
final class Navigator: ObservableObject {
    @Published var path = NavigationPath()

    nonisolated init() {}

    func open(_ route: ThreadRoute) {
        path.append(route)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
