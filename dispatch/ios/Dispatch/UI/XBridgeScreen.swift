import SwiftUI

/// Set up the RSS bridge that X sources read through.
struct XBridgeScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var catalog: CatalogStore

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Picker("Bridge", selection: $settings.xBridge.kind) {
                    ForEach(XBridgeKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
            } header: {
                Text("Type")
            } footer: {
                Text(settings.xBridge.kind.detail)
            }

            if settings.xBridge.kind == .nitter || settings.xBridge.kind == .rsshub {
                Section {
                    TextField(settings.xBridge.kind.hostPlaceholder, text: $settings.xBridge.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Instance")
                } footer: {
                    Text("A host on your own network — 192.168.x.x, 10.x.x.x or a .local name — "
                         + "defaults to http and is allowed to use it. Anything else defaults to "
                         + "https. Type the scheme yourself to override either.")
                }
            }

            if settings.xBridge.kind == .custom {
                Section {
                    TextField("https://host/path/{handle}", text: $settings.xBridge.template)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("URL template")
                } footer: {
                    Text("Must contain {handle}. It is replaced with each X source's handle, and the "
                         + "result has to return RSS or Atom.")
                }
            }

            if settings.xBridge.kind != .none {
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("Test the bridge", systemImage: "checkmark.seal")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting || !settings.xBridge.isConfigured)

                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    if let example = settings.xBridge.feedURL(handle: exampleHandle) {
                        LabeledContent("Resolves to") {
                            Text(example.absoluteString)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            Section {
                ForEach(xSources) { source in
                    LabeledContent(source.name, value: "@" + XBridge.normalizeHandle(source.endpoint))
                        .font(.system(size: 14))
                }
            } header: {
                Text("X sources")
            } footer: {
                Text("Change these handles in Settings › Sources.")
            }

            Section {
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Why this is needed")
            }
        }
        .navigationTitle("X bridge")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var xSources: [Source] {
        catalog.sources.filter { $0.kind == .x }
    }

    private var exampleHandle: String {
        xSources.first.map { XBridge.normalizeHandle($0.endpoint) } ?? "zerohedge"
    }

    private var explanation: String {
        "X has no free public read API, so no app can fetch a timeline directly. A bridge is a "
        + "small server that reads X and republishes it as RSS. Public instances get rate limited "
        + "quickly, so a self-hosted one is the arrangement that keeps working.\n\n"
        + "With no bridge, X sources fall back to the publisher's own RSS feed — which for "
        + "ZeroHedge is the same newsroom, just the site feed rather than the timeline."
    }

    private func test() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        guard let url = settings.xBridge.feedURL(handle: exampleHandle) else {
            testResult = "The bridge is not configured."
            return
        }

        do {
            let data = try await HTTP.shared.feedData(from: url)
            let feed = try FeedParser.parse(data)
            testResult = "Working — \(feed.items.count) item"
                + (feed.items.count == 1 ? "" : "s")
                + " from @\(exampleHandle)."
        } catch {
            let message = (error as? FeedError)?.errorDescription
                ?? FeedError.from(error).errorDescription
                ?? "Failed."
            testResult = "\(message)\n\nX sources will use their backup feeds."
        }
    }
}
