import Foundation

/// A video that lives on this device.
///
/// The metadata is snapshotted at download time rather than re-fetched. The
/// whole point of the offline library is that it works with no network, and a
/// title that renders only when the instance is reachable defeats it. It also
/// survives the video being deleted upstream, which is the other case where
/// "offline" has to mean something.
struct DownloadedVideo: Identifiable, Codable, Hashable {

    let uuid: String
    let title: String
    let channelName: String
    let durationSeconds: Int
    let resolutionLabel: String
    let byteSize: Int
    let downloadedAt: Date
    /// Filenames, not URLs. The container directory moves between installs and
    /// OS upgrades, so an absolute path stored today may not resolve tomorrow.
    let videoFilename: String
    let thumbnailFilename: String?
    /// Which instance it came from, for the "open on the web" affordance.
    let instanceHost: String

    var id: String { uuid }

    var videoURL: URL? { OfflineLibrary.mediaDirectory?.appendingPathComponent(videoFilename) }

    var thumbnailURL: URL? {
        guard let thumbnailFilename else { return nil }
        return OfflineLibrary.mediaDirectory?.appendingPathComponent(thumbnailFilename)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    var formattedDuration: String {
        guard durationSeconds > 0 else { return "" }
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        let seconds = durationSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Enough of a `Video` to hand to the player, without a network round trip.
    var placeholderVideo: Video? {
        Video.offlinePlaceholder(
            uuid: uuid, name: title, channelName: channelName, duration: durationSeconds
        )
    }
}

/// Where downloads live, and the manifest that describes them.
enum OfflineLibrary {

    private static let directoryName = "Vela"
    private static let mediaDirectoryName = "Downloads"
    private static let manifestName = "downloads.json"

    /// Application Support rather than Documents or Caches.
    ///
    /// Caches is wrong because the system evicts it under pressure and a
    /// download the reader deliberately kept would vanish. Documents is wrong
    /// because it exposes the files in the Files app as user documents, which
    /// these are not — they are app state.
    private static var containerDirectory: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let url = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static var mediaDirectory: URL? {
        guard let container = containerDirectory else { return nil }
        let url = container.appendingPathComponent(mediaDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Downloads are re-fetchable in principle, but the reader asked for
            // them; backing up gigabytes of video to iCloud is not what they
            // meant, so the directory is excluded.
            excludeFromBackup(url)
        }
        return url
    }

    private static var manifestURL: URL? {
        containerDirectory?.appendingPathComponent(manifestName)
    }

    static func loadManifest() -> [DownloadedVideo] {
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL) else { return [] }
        let entries = (try? JSONDecoder().decode([DownloadedVideo].self, from: data)) ?? []
        // Drop entries whose file is gone — deleted by the system, or lost in a
        // restore. A library row that plays nothing is worse than no row.
        return entries.filter { entry in
            guard let url = entry.videoURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func saveManifest(_ entries: [DownloadedVideo]) {
        guard let manifestURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    static func removeFiles(for entry: DownloadedVideo) {
        if let url = entry.videoURL { try? FileManager.default.removeItem(at: url) }
        if let url = entry.thumbnailURL { try? FileManager.default.removeItem(at: url) }
    }

    static func totalBytesOnDisk(_ entries: [DownloadedVideo]) -> Int {
        entries.reduce(0) { $0 + $1.byteSize }
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

extension Video {
    /// Build the minimum a player needs from stored metadata.
    ///
    /// `Video` decodes from JSON only, so this round-trips a small synthetic
    /// payload rather than adding a second initialiser that every future field
    /// would have to be threaded through.
    static func offlinePlaceholder(uuid: String, name: String,
                                   channelName: String, duration: Int) -> Video? {
        let payload: [String: Any] = [
            "uuid": uuid,
            "name": name,
            "duration": duration,
            "channel": ["name": channelName, "displayName": channelName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(Video.self, from: data)
    }
}
