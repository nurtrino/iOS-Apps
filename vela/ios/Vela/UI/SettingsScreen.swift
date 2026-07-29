import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var showingSignIn = false
    @State private var showingInstancePicker = false
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                instanceSection

                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    Picker("Default sort", selection: $settings.defaultSort) {
                        ForEach(VideoSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                }

                Section {
                    Picker("Download quality", selection: $settings.downloadQuality) {
                        ForEach(DownloadQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Toggle("Only download on Wi-Fi", isOn: $settings.downloadOnWiFiOnly)
                    HStack {
                        Text("Storage used")
                        Spacer()
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(downloads.totalBytes), countStyle: .file
                        ))
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Downloads continue while the app is in the background and stay on this device until you remove them. Each uploader decides whether their videos may be downloaded.")
                }

                Section {
                    Toggle("Show sensitive videos", isOn: $settings.includeNSFW)
                } header: {
                    Text("Content")
                } footer: {
                    Text("Instances flag videos their moderators consider sensitive. Off hides them from every list.")
                }

                Section("Storage") {
                    Button(cacheCleared ? "Image cache cleared" : "Clear image cache") {
                        Task {
                            await ImageLoader.shared.clearCache()
                            cacheCleared = true
                        }
                    }
                    .disabled(cacheCleared)
                }

                Section {
                    Link("What is PeerTube?", destination: URL(string: "https://joinpeertube.org")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Vela is a client for PeerTube, an open federated video network. It shows no ads because PeerTube serves none, and downloads only what each uploader has allowed. Not affiliated with the PeerTube project.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSignIn) { SignInSheet() }
            .sheet(isPresented: $showingInstancePicker) { InstancePickerSheet() }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if let user = auth.user {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.account?.displayName ?? user.username)
                            .font(.system(size: 15, weight: .medium))
                        Text("@\(user.username)@\(auth.instance.host)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button("Sign Out", role: .destructive) {
                    Task { await auth.signOut() }
                }
            } else {
                Button("Sign In") { showingSignIn = true }
                Text("Optional — browsing, playback and downloads all work signed out.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var instanceSection: some View {
        Section {
            Button {
                showingInstancePicker = true
            } label: {
                HStack {
                    Text("Instance")
                    Spacer()
                    Text(auth.instance.host)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            if let description = auth.instanceConfig?.shortDescription {
                Text(description)
            } else {
                Text("PeerTube is federated: each instance is its own server, and most show videos from the others they connect to.")
            }
        }
    }
}

/// Sign in to the currently selected instance.
struct SignInSheet: View {

    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username or email", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Sign in to \(auth.instance.host)")
                } footer: {
                    Text("Your password is sent once to this instance to get a token, and is never stored. The token is kept in the device Keychain.")
                }

                if let error = auth.signInError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await auth.signIn(username: username, password: password)
                            if auth.isSignedIn { dismiss() }
                        }
                    } label: {
                        if auth.isSigningIn {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || auth.isSigningIn)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Choose which server to browse.
struct InstancePickerSheet: View {

    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var custom = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("instance.example", text: $custom)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("Use This Instance") {
                        switchTo(Instance(host: custom))
                    }
                    .disabled(!Instance(host: custom).isPlausible)
                } header: {
                    Text("Custom")
                } footer: {
                    Text("Any PeerTube server works. Switching signs you out, because an account belongs to the instance that issued it.")
                }

                Section("Suggestions") {
                    ForEach(Instance.suggestions) { instance in
                        Button {
                            switchTo(instance)
                        } label: {
                            HStack {
                                Text(instance.host)
                                Spacer()
                                if instance == auth.instance {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Instance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func switchTo(_ instance: Instance) {
        Task {
            await auth.switchTo(instance)
            dismiss()
        }
    }
}
