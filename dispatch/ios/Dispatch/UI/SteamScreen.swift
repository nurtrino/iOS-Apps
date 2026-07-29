import SwiftUI

/// Steam library setup and per-game muting.
struct SteamScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: SteamLibraryStore

    @State private var keyDraft = ""
    @State private var appIDDraft = ""
    @State private var isAddingApp = false
    @State private var webLink: WebLink?

    var body: some View {
        Form {
            credentialsSection
            librarySection
            tuningSection
            gamesSection
        }
        .navigationTitle("Steam")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url).ignoresSafeArea()
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section {
            if settings.hasSteamKey {
                HStack {
                    Label("API key saved", systemImage: "key.fill")
                        .foregroundStyle(Palette.accent)
                    Spacer()
                    Button("Remove") {
                        Task { await settings.clearSteamKey() }
                    }
                    .foregroundStyle(.red)
                }
            } else {
                SecureField("Steam Web API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save key") {
                    Task {
                        await settings.saveSteamKey(keyDraft)
                        keyDraft = ""
                    }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    webLink = WebLink(url: URL(string: "https://steamcommunity.com/dev/apikey")!)
                } label: {
                    Label("Get a key from Steam", systemImage: "arrow.up.right.square")
                }
            }

            TextField("Steam ID or profile name", text: $settings.steamID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Account")
        } footer: {
            Text("The key is stored in the iOS Keychain and is only ever sent to Valve. It is used "
                 + "once, to list what you own — news itself needs no key, so you can skip all of "
                 + "this and add games by App ID below.")
        }
    }

    private var librarySection: some View {
        Section {
            Button {
                Task {
                    guard let key = await settings.steamKey() else { return }
                    await library.sync(key: key, identifier: settings.steamID)
                }
            } label: {
                HStack {
                    Label("Sync library", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if library.phase.isBusy { ProgressView() }
                }
            }
            .disabled(!settings.hasSteamKey
                      || settings.steamID.trimmingCharacters(in: .whitespaces).isEmpty
                      || library.phase.isBusy)

            if let message = library.phase.errorMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            } else if let lastSync = library.lastSync {
                LabeledContent("Last synced",
                               value: lastSync.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 14))
            }
        } footer: {
            Text("Needs “Game details” set to Public in your Steam privacy settings. If Steam "
                 + "returns nothing, that is almost always why.")
        }
    }

    private var tuningSection: some View {
        Section {
            Stepper(value: $settings.steamMaxGames, in: 1...40) {
                LabeledContent("Games followed", value: "\(settings.steamMaxGames)")
            }
            Stepper(value: $settings.steamItemsPerGame, in: 1...10) {
                LabeledContent("Items per game", value: "\(settings.steamItemsPerGame)")
            }

            Toggle("Readable scripts only", isOn: $settings.steamLatinOnly)
        } header: {
            Text("Feed")
        } footer: {
            Text("Games are followed most-recently-played first. Each one is a separate request, "
                 + "so following forty of them makes the Gaming section noticeably slower to refresh.\n\n"
                 + "Steam's news API has no language parameter, so a studio posting in Chinese or "
                 + "Russian lands in the same list as one posting in English. “Readable scripts "
                 + "only” drops announcements whose title is mostly non-Latin.")
        }
    }

    // MARK: - Games

    private var gamesSection: some View {
        Section {
            if isAddingApp {
                HStack {
                    TextField("App ID, e.g. 730", text: $appIDDraft)
                        .keyboardType(.numberPad)
                    Button("Add") {
                        guard let appID = Int(appIDDraft.trimmingCharacters(in: .whitespaces)) else { return }
                        Task {
                            await library.addManual(appID: appID)
                            appIDDraft = ""
                            isAddingApp = false
                        }
                    }
                    .disabled(Int(appIDDraft.trimmingCharacters(in: .whitespaces)) == nil)
                }
            } else {
                Button {
                    isAddingApp = true
                } label: {
                    Label("Add a game by App ID", systemImage: "plus")
                }
            }

            ForEach(library.sortedGames) { game in
                gameRow(game)
            }
            .onDelete { offsets in
                let games = library.sortedGames
                for index in offsets where games.indices.contains(index) {
                    library.remove(appID: games[index].appID)
                }
            }
        } header: {
            HStack {
                Text("Library")
                Spacer()
                if !library.games.isEmpty {
                    Text("\(library.activeGames.count) of \(library.games.count) followed")
                        .font(.system(size: 11))
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("An App ID is the number in a store URL: store.steampowered.com/app/730/. "
                 + "Swipe a game to remove it, or tap to stop following it without removing it.")
        }
    }

    private func gameRow(_ game: SteamGame) -> some View {
        Button {
            library.setMuted(!library.isMuted(appID: game.appID), appID: game.appID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: library.isMuted(appID: game.appID) ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(library.isMuted(appID: game.appID) ? Color.secondary : Palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(playtimeLabel(game))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func playtimeLabel(_ game: SteamGame) -> String {
        if game.playtimeTwoWeeks > 0 {
            return "\(hours(game.playtimeTwoWeeks)) in the last two weeks"
        }
        if game.playtimeForever > 0 {
            return "\(hours(game.playtimeForever)) total"
        }
        return "App \(game.appID)"
    }

    private func hours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : String(format: "%.0fh", Double(minutes) / 60)
    }
}
