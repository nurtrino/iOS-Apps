import SwiftUI

/// AI summaries setup: the toggle, the key, and — because this is the only
/// feature that sends anything off the device — an exact statement of what
/// goes over the wire.
struct SummariesScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var summaries: SummaryStore

    @State private var keyDraft = ""
    @State private var webLink: WebLink?

    private enum TestState: Equatable {
        case idle
        case testing
        case passed
        case failed(String)
    }
    @State private var testState = TestState.idle

    var body: some View {
        Form {
            featureSection
            keySection
            testSection
        }
        .navigationTitle("AI summaries")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url).ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var featureSection: some View {
        Section {
            Toggle(isOn: $settings.aiSummaries) {
                Label("Write the brief", systemImage: "text.badge.star")
            }

            LabeledContent("Model", value: SummaryAPI.model)
        } header: {
            Text("Summaries")
        } footer: {
            Text(featureFooter)
        }
    }

    /// Footers live in plain `String` properties — long `+` chains inline in a
    /// `Text` inside a ViewBuilder are what made SettingsScreen time out the
    /// type checker on CI.
    private var featureFooter: String {
        "When this is on, the brief at the top of each section opens with a few bullets "
            + "written by Claude saying what just happened, generated from the newest "
            + "headlines in that section — including the wires shown in their own block, "
            + "since a frontline channel is the best material there is for what just "
            + "happened.\n\n"
            + "What is sent to Anthropic: those headlines, their source names and their ages. "
            + "Nothing else — not article text, not what you read, not your Steam library. "
            + "A summary is only regenerated when the headlines change, a few times an hour "
            + "at most. Haiku is used rather than a larger model because the job is four "
            + "lines off headlines that are already written, so each brief costs a small "
            + "fraction of a cent on your key."
    }

    private var keySection: some View {
        Section {
            if settings.hasAnthropicKey {
                HStack {
                    Label("API key saved", systemImage: "key.fill")
                        .foregroundStyle(Palette.accent)
                    Spacer()
                    Button("Remove") {
                        Task {
                            await settings.clearAnthropicKey()
                            summaries.clearAll()
                            testState = .idle
                        }
                    }
                    .foregroundStyle(.red)
                }
            } else {
                SecureField("Anthropic API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save key") {
                    Task {
                        await settings.saveAnthropicKey(keyDraft)
                        keyDraft = ""
                        testState = .idle
                    }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    webLink = WebLink(url: URL(string: "https://console.anthropic.com/settings/keys")!)
                } label: {
                    Label("Get a key from Anthropic", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Key")
        } footer: {
            Text(keyFooter)
        }
    }

    private var keyFooter: String {
        "The key is stored in the iOS Keychain, never leaves this device except to "
            + "Anthropic, and does not travel in backups. Removing it also deletes the "
            + "summaries it wrote."
    }

    private var testSection: some View {
        Section {
            Button {
                testState = .testing
                Task {
                    guard let key = await settings.anthropicKey() else {
                        testState = .failed("No key saved.")
                        return
                    }
                    do {
                        try await SummaryAPI.verify(key: key)
                        testState = .passed
                    } catch {
                        testState = .failed((error as? SummaryAPI.SummaryError)?.errorDescription
                                            ?? error.localizedDescription)
                    }
                }
            } label: {
                HStack {
                    Label("Test the key", systemImage: "checkmark.seal")
                    Spacer()
                    if testState == .testing { ProgressView() }
                }
            }
            .disabled(!settings.hasAnthropicKey || testState == .testing)

            switch testState {
            case .passed:
                Label("The key works.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            case .idle, .testing:
                EmptyView()
            }
        } footer: {
            Text(testFooter)
        }
    }

    private var testFooter: String {
        "Sends one tiny request so a bad key fails here, loudly, instead of failing "
            + "quietly at the top of every section."
    }
}
