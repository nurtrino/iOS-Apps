import SwiftUI

/// The two things Claude does here, the key they need, and — because these are
/// the only features that send anything off the device — an exact statement of
/// what goes over the wire.
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
            sortingSection
            featureSection
            keySection
            testSection
        }
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url).ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var sortingSection: some View {
        Section {
            Toggle(isOn: $settings.aiSorting) {
                Label("File stories into sections", systemImage: "arrow.triangle.branch")
            }
        } header: {
            Text("Sorting")
        } footer: {
            Text(sortingFooter)
        }
    }

    private var sortingFooter: String {
        "Stories from a general outlet — ZeroHedge, Citizen Free Press — have to be filed into "
            + "War, Politics or Markets one at a time. On device that is a list of five hundred "
            + "weighted terms, which is fast and free and knows only the words it was given: a "
            + "headline using none of them gets filed by guess, and on a source set to skip what "
            + "fits nowhere it disappeared instead.\n\n"
            + "With this on, Claude decides. Forty headlines go in one request, each answer is "
            + "stored against that story forever, and a story already filed is never sent again — "
            + "so a busy day is one or two requests. The term list stays as the offline answer: "
            + "no key, no network or a failed request and nothing is lost, stories are just filed "
            + "the old way until the next refresh.\n\n"
            + "Only headline text is sent. No article bodies, no reading history."
    }

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
        "The brief at the top of each section is this: a few bullets "
            + "written by Claude saying what just happened, generated from the newest "
            + "headlines in that section. With this off, or with no key saved, there is no "
            + "brief anywhere in the app rather than an empty one.\n\n"
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
