import Foundation
import SwiftUI

/// Whether a YouTube key exists, observable from the view layer.
///
/// `YouTubeAPI` is an actor, so a view cannot ask it anything synchronously —
/// and "is there a key" is a question every YouTube screen asks during `body`.
/// This holds the answer on the main actor and is the one place that writes the
/// key to both the Keychain and the client, so the two can never disagree.
@MainActor
final class APIKeyStatus: ObservableObject {

    static let shared = APIKeyStatus()

    @Published private(set) var hasKey = false
    /// The last four characters, for confirming which key is installed without
    /// ever putting the whole thing back on screen.
    @Published private(set) var keySuffix: String?
    @Published private(set) var spentUnits = 0

    func restore() async {
        let stored = await APIKeyStore.shared.load()
        await YouTubeAPI.shared.use(apiKey: stored)
        apply(stored)
    }

    func save(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        await APIKeyStore.shared.save(trimmed)
        await YouTubeAPI.shared.use(apiKey: trimmed)
        apply(trimmed.isEmpty ? nil : trimmed)
    }

    func clear() async {
        await APIKeyStore.shared.clear()
        await YouTubeAPI.shared.use(apiKey: nil)
        apply(nil)
    }

    func refreshQuota() async {
        spentUnits = await YouTubeAPI.shared.spentUnits
    }

    private func apply(_ key: String?) {
        hasKey = key != nil
        keySuffix = key.map { String($0.suffix(4)) }
    }
}
