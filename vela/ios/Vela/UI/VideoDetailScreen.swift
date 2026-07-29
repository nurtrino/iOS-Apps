import SwiftUI

/// One video: player entry point, metadata, and the offline actions.
struct VideoDetailScreen: View {

    let uuid: String

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var store = VideoDetailStore()

    @State private var showingQualityPicker = false
    @State private var saveMessage: String?
    @State private var isSavingToPhotos = false
    @State private var descriptionExpanded = false

    var body: some View {
        Group {
            switch store.phase {
            case .loading, .idle:
                LoadingState()
            case .failed(let message):
                ErrorState(message: message) {
                    Task { await store.load(uuid: uuid, force: true) }
                }
            default:
                if let details = store.details {
                    content(details)
                } else {
                    LoadingState()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: uuid) { await store.load(uuid: uuid) }
        .alert("Save to Photos", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
    }

    private func content(_ details: VideoDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                poster(details)

                Text(details.video.name)
                    .font(.system(size: 19, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(Format.count(details.video.views) + " views")
                    if let published = details.video.publishedAt {
                        Text("·")
                        Text(RelativeTime.string(from: published))
                    }
                    if details.video.likes > 0 {
                        Text("·")
                        Label(Format.count(details.video.likes), systemImage: "hand.thumbsup")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                channelRow(details)
                actions(details)

                if let description = details.description, !description.isEmpty {
                    descriptionBlock(description)
                }

                if !details.tags.isEmpty {
                    tagRow(details.tags)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 140)
        }
    }

    // MARK: - Pieces

    private func poster(_ details: VideoDetails) -> some View {
        Button {
            play(details)
        } label: {
            Thumbnail(
                url: auth.instance.resolve(details.video.previewPath ?? details.video.thumbnailPath),
                duration: details.video.formattedDuration,
                isLive: details.video.isLive,
                cornerRadius: 14
            )
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 8)
            }
        }
        .buttonStyle(.plain)
    }

    private func channelRow(_ details: VideoDetails) -> some View {
        HStack(spacing: 10) {
            if let channel = details.video.channel {
                RemoteImage(url: auth.instance.resolve(channel.bestAvatarPath))
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(channel.handle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(_ details: VideoDetails) -> some View {
        HStack(spacing: 10) {
            Button {
                play(details)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)

            downloadButton(details)
        }

        if let entry = downloads.entry(for: uuid) {
            offlineActions(entry)
        } else if !details.downloadEnabled {
            // Stated rather than left as an unexplained absence — this is the
            // uploader's decision, not a missing feature.
            Label("The uploader has turned off downloads for this video.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let progress = downloads.active[uuid] {
            downloadProgress(progress)
        }
    }

    @ViewBuilder
    private func downloadButton(_ details: VideoDetails) -> some View {
        if downloads.isDownloaded(uuid) {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        } else if downloads.isDownloading(uuid) {
            Button(role: .destructive) {
                downloads.cancel(uuid)
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else if !details.downloadableFiles.isEmpty {
            Button {
                showingQualityPicker = true
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .confirmationDialog("Download quality", isPresented: $showingQualityPicker) {
                ForEach(details.downloadableFiles) { file in
                    Button(fileLabel(file)) {
                        downloads.download(details, file: file, instance: auth.instance)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose a resolution. Larger files play better on a big screen and cost more space.")
            }
        }
    }

    private func downloadProgress(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
                .tint(Palette.accent)
            Text(progress.formattedProgress)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func offlineActions(_ entry: DownloadedVideo) -> some View {
        HStack(spacing: 10) {
            Button {
                saveToPhotos(entry)
            } label: {
                if isSavingToPhotos {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Save to Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSavingToPhotos)

            Button(role: .destructive) {
                downloads.delete(entry)
            } label: {
                Label("Remove", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func descriptionBlock(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            Button(descriptionExpanded ? "Show less" : "Show more") {
                withAnimation { descriptionExpanded.toggle() }
            }
            .font(.system(size: 13, weight: .medium))
            .tint(Palette.accent)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tagRow(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Palette.surfaceStrong, in: Capsule())
                }
            }
        }
    }

    // MARK: - Actions

    /// Prefers the downloaded copy when there is one — it is faster, works with
    /// no signal, and is what somebody who downloaded it expects to get.
    private func play(_ details: VideoDetails) {
        if let entry = downloads.entry(for: uuid), let localURL = entry.videoURL {
            player.play(details.video, url: localURL, isOffline: true)
        } else if let streamURL = details.streamURL {
            player.play(details.video, url: streamURL, isOffline: false)
        } else {
            return
        }
        player.isExpanded = true
    }

    private func saveToPhotos(_ entry: DownloadedVideo) {
        guard let url = entry.videoURL else { return }
        isSavingToPhotos = true
        Task {
            do {
                try await PhotoSaver.save(fileURL: url)
                saveMessage = "Saved to your photo library."
            } catch {
                saveMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isSavingToPhotos = false
        }
    }

    private func fileLabel(_ file: VideoFile) -> String {
        if let size = file.formattedSize { return "\(file.displayName) · \(size)" }
        return file.displayName
    }
}
