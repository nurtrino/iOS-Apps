import SwiftUI

/// Everything downloaded to this device.
///
/// Deliberately works with no network at all: titles, poster frames and
/// playback all come off disk, so the screen behaves the same on a plane as on
/// wifi. That is the entire point of a download.
struct LibraryScreen: View {

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerEngine

    @State private var pendingDelete: DownloadedVideo?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.library.isEmpty && downloads.active.isEmpty {
                    EmptyState(
                        title: "No downloads",
                        message: "Videos you download stay here and play without a connection.",
                        systemImage: "arrow.down.circle"
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !downloads.library.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                downloads.deleteAll()
                            } label: {
                                Label("Remove All Downloads", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove this download?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingDelete { downloads.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The file is deleted from this device. You can download it again later.")
        }
    }

    private var list: some View {
        List {
            if !downloads.active.isEmpty {
                Section("Downloading") {
                    ForEach(Array(downloads.active.values).sorted { $0.title < $1.title },
                            id: \.uuid) { progress in
                        activeRow(progress)
                    }
                }
            }

            if !downloads.library.isEmpty {
                Section {
                    ForEach(downloads.library) { entry in
                        Button {
                            play(entry)
                        } label: {
                            downloadedRow(entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = entry
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("On this device")
                } footer: {
                    Text("\(downloads.library.count) video\(downloads.library.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(downloads.totalBytes), countStyle: .file))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            // Reserves room for the docked mini-player.
            Color.clear.frame(height: player.nowPlaying != nil ? 70 : 0)
        }
    }

    private func activeRow(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
            ProgressView(value: progress.fraction).tint(Palette.accent)
            HStack {
                Text(progress.formattedProgress)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { downloads.cancel(progress.uuid) }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func downloadedRow(_ entry: DownloadedVideo) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: entry.thumbnailURL)
                .frame(width: 108, height: 61)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if !entry.formattedDuration.isEmpty {
                        Text(entry.formattedDuration)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.channelName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(entry.resolutionLabel) · \(entry.formattedSize)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func play(_ entry: DownloadedVideo) {
        guard let url = entry.videoURL, let video = entry.placeholderVideo else { return }
        player.play(video, url: url, isOffline: true)
        player.isExpanded = true
    }
}
