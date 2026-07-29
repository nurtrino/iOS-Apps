import SwiftUI

/// Regions offered for the trending chart.
///
/// The endpoint takes any ISO 3166-1 alpha-2 code, but a free-text field for a
/// two-letter code is a bad control: a typo returns an empty chart with no
/// explanation. A short list covers where people actually are, and the device's
/// own region is always included even when it is not on it.
struct TrendingRegion: Hashable {
    let code: String
    let name: String

    static let common: [TrendingRegion] = {
        var regions = [
            TrendingRegion(code: "US", name: "United States"),
            TrendingRegion(code: "GB", name: "United Kingdom"),
            TrendingRegion(code: "CA", name: "Canada"),
            TrendingRegion(code: "AU", name: "Australia"),
            TrendingRegion(code: "IE", name: "Ireland"),
            TrendingRegion(code: "DE", name: "Germany"),
            TrendingRegion(code: "FR", name: "France"),
            TrendingRegion(code: "ES", name: "Spain"),
            TrendingRegion(code: "IT", name: "Italy"),
            TrendingRegion(code: "NL", name: "Netherlands"),
            TrendingRegion(code: "SE", name: "Sweden"),
            TrendingRegion(code: "BR", name: "Brazil"),
            TrendingRegion(code: "MX", name: "Mexico"),
            TrendingRegion(code: "IN", name: "India"),
            TrendingRegion(code: "JP", name: "Japan"),
            TrendingRegion(code: "KR", name: "South Korea"),
            TrendingRegion(code: "ZA", name: "South Africa"),
        ]
        // Without this, somebody in a country not on the list sees the picker
        // snap to a value they never chose.
        if let local = Locale.current.region?.identifier,
           !regions.contains(where: { $0.code == local }) {
            let name = Locale.current.localizedString(forRegionCode: local) ?? local
            regions.insert(TrendingRegion(code: local, name: name), at: 0)
        }
        return regions
    }()
}

/// Entering the YouTube Data API key.
struct APIKeySheet: View {

    @EnvironmentObject private var keys: APIKeyStatus
    @Environment(\.dismiss) private var dismiss

    @State private var entry = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A plain field rather than SecureField: this is pasted from
                    // a browser and mistyping it produces a 400 that reads like
                    // a network problem, so it should be visible to check.
                    TextField("AIza…", text: $entry)
                        .font(.system(size: 15).monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("YouTube Data API key")
                } footer: {
                    Text("Stored in this device's Keychain, and never sent anywhere except Google's API.")
                }

                Section {
                    Button {
                        Task {
                            isSaving = true
                            await keys.save(entry)
                            isSaving = false
                            dismiss()
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

                    if keys.hasKey {
                        Button("Remove key", role: .destructive) {
                            Task {
                                await keys.clear()
                                dismiss()
                            }
                        }
                    }
                }

                Section("How to get one") {
                    steps
                    Link(
                        "Google Cloud Console",
                        destination: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!
                    )
                }
            }
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Create a project in the Google Cloud Console.")
            step(2, "Enable the YouTube Data API v3 for it.")
            step(3, "Under Credentials, create an API key.")
            step(4, "Paste it above.")
            Text("The free tier gives 10,000 quota units a day. A search costs 100 of them; browsing trending and channels costs 1 per page.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Palette.surfaceStrong, in: Circle())
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
