import Foundation

/// The game library the Gaming section pulls news for.
///
/// Two ways in, because the automatic one has a real failure mode: Valve's
/// `GetOwnedGames` needs a Web API key *and* a profile whose "Game details"
/// privacy is public, and a lot of accounts are not. Rather than dead-ending
/// there, games can be added by App ID by hand, and the news endpoint needs no
/// key at all — so the section works either way.
@MainActor
final class SteamLibraryStore: ObservableObject {

    @Published private(set) var games: [SteamGame] = []
    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var lastSync: Date?

    /// Games the user has switched off. Kept separately from `games` so a
    /// library re-sync does not silently re-enable everything they muted.
    @Published private(set) var mutedAppIDs: Set<Int> = []

    private let gamesFile = "steam-games"
    private let mutedFile = "steam-muted"
    private let syncFile = "steam-sync"

    init(load: Bool = true) {
        guard load else { return }
        games = DiskStore.load([SteamGame].self, from: gamesFile) ?? []
        mutedAppIDs = Set(DiskStore.load([Int].self, from: mutedFile) ?? [])
        // Wrapped in an array, not stored bare. `JSONEncoder` refuses to write
        // a top-level `Date` — it is a JSON fragment, not a document — so
        // saving one silently writes nothing and the timestamp never persists.
        lastSync = DiskStore.load([Date].self, from: syncFile)?.first
        if !games.isEmpty { phase = .loaded }
    }

    /// Games actually used to build the feed.
    var activeGames: [SteamGame] {
        games.filter { !mutedAppIDs.contains($0.appID) }
    }

    /// Sorted for the management screen: recently played first, then the rest
    /// alphabetically. Playtime order alone buries everything unplayed under a
    /// long tail of zeroes in arbitrary order.
    var sortedGames: [SteamGame] {
        games.sorted { left, right in
            if left.recencyRank != right.recencyRank { return left.recencyRank > right.recencyRank }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    // MARK: - Sync

    /// Pulls the library from Steam. Needs a key and a resolved 64-bit ID.
    ///
    /// `identifier` may be a 64-bit ID or a vanity name — people copy whichever
    /// their profile URL shows, and the two are indistinguishable to a user.
    func sync(key: String, identifier: String) async {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            phase = .failed("Add a Steam Web API key first.")
            return
        }
        guard !trimmedID.isEmpty else {
            phase = .failed("Add your Steam ID or profile name first.")
            return
        }

        phase = games.isEmpty ? .loading : .refreshing

        do {
            let steamID = try await resolve(identifier: trimmedID, key: trimmedKey)
            let fetched = try await SteamAPI.shared.ownedGames(key: trimmedKey, steamID: steamID)

            // Hand-added games have no owner record, so a sync must not drop
            // them — they are merged in rather than replaced.
            let fetchedIDs = Set(fetched.map(\.appID))
            let manual = games.filter { !fetchedIDs.contains($0.appID) && $0.playtimeForever == 0 }

            games = fetched + manual
            lastSync = Date()
            phase = .loaded
            persist()
        } catch {
            phase = .failed((error as? FeedError)?.errorDescription
                            ?? FeedError.from(error).errorDescription
                            ?? "Could not read your Steam library.")
        }
    }

    /// A 17-digit number is already a Steam ID; anything else is a vanity name.
    private func resolve(identifier: String, key: String) async throws -> String {
        let digitsOnly = identifier.allSatisfy(\.isNumber)
        if digitsOnly && identifier.count >= 16 { return identifier }

        // Accept a pasted profile URL in either of its two shapes.
        var vanity = identifier
        for marker in ["steamcommunity.com/id/", "steamcommunity.com/profiles/"] {
            if let range = vanity.range(of: marker) {
                vanity = String(vanity[range.upperBound...])
            }
        }
        vanity = vanity.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if vanity.allSatisfy(\.isNumber) && vanity.count >= 16 { return vanity }

        return try await SteamAPI.shared.resolveVanity(key: key, vanity: vanity)
    }

    // MARK: - Manual entry

    /// Adds a game by App ID, resolving its name in the background.
    @discardableResult
    func addManual(appID: Int) async -> Bool {
        guard appID > 0, !games.contains(where: { $0.appID == appID }) else { return false }

        var game = SteamGame(appID: appID, name: "App \(appID)",
                             playtimeForever: 0, playtimeTwoWeeks: 0)
        games.append(game)
        persist()

        // The name is cosmetic, so the row appears immediately and fills in
        // when — or if — the store answers.
        if let name = await SteamAPI.shared.storeName(appID: appID) {
            game.name = name
            if let index = games.firstIndex(where: { $0.appID == appID }) {
                games[index] = game
                persist()
            }
        }
        return true
    }

    func remove(appID: Int) {
        games.removeAll { $0.appID == appID }
        mutedAppIDs.remove(appID)
        persist()
    }

    func setMuted(_ muted: Bool, appID: Int) {
        if muted { mutedAppIDs.insert(appID) } else { mutedAppIDs.remove(appID) }
        DiskStore.save(Array(mutedAppIDs), to: mutedFile)
    }

    func isMuted(appID: Int) -> Bool {
        mutedAppIDs.contains(appID)
    }

    func clear() {
        games = []
        mutedAppIDs = []
        lastSync = nil
        phase = .idle
        persist()
        DiskStore.save(Array(mutedAppIDs), to: mutedFile)
    }

    private func persist() {
        DiskStore.save(games, to: gamesFile)
        DiskStore.save(lastSync.map { [$0] } ?? [], to: syncFile)
    }
}
