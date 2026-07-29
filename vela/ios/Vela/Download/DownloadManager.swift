import Foundation
import UIKit

/// A download in flight.
struct DownloadProgress: Equatable {
    let uuid: String
    let title: String
    var bytesWritten: Int64
    var bytesExpected: Int64
    var isFinishing: Bool = false

    var fraction: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1, Double(bytesWritten) / Double(bytesExpected))
    }

    var formattedProgress: String {
        guard bytesExpected > 0 else {
            return ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
        }
        let done = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: bytesExpected, countStyle: .file)
        return "\(done) of \(total)"
    }
}

/// Downloads videos for offline playback.
///
/// Built on a **background** `URLSession`, which is the difference between a
/// download that survives the app being suspended and one that dies the moment
/// somebody switches apps. The system owns the transfer and wakes the app when
/// it finishes; the trade is that the delegate is an `NSObject` receiving
/// callbacks off the main thread, so every published change hops back.
final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()

    /// Stable across launches — the system reconnects an app to its background
    /// session by this identifier, and changing it orphans transfers already
    /// running.
    private static let sessionIdentifier = "net.vela.downloads"

    @Published private(set) var active: [String: DownloadProgress] = [:]
    @Published private(set) var library: [DownloadedVideo] = []
    @Published var lastError: String?

    /// Set by the app delegate when the system wakes us for a finished
    /// background transfer; called once everything has been processed.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        // Let the system relaunch the app in the background to deliver the
        // finished file, rather than waiting for the next manual launch.
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Remove and return every pending identifier for a video.
    private func takePendingIdentifiers(for uuid: String) -> Set<Int> {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let identifiers = Set(pending.filter { $0.value.uuid == uuid }.map(\.key))
        identifiers.forEach { pending[$0] = nil }
        return identifiers
    }

    /// Task identifier to the metadata needed once the bytes land. Held here
    /// because a background task can outlive the process that started it.
    private var pending: [Int: PendingDownload] = [:]
    private let pendingLock = NSLock()

    private struct PendingDownload {
        let uuid: String
        let title: String
        let channelName: String
        let duration: Int
        let resolutionLabel: String
        let thumbnailURL: URL?
        let instanceHost: String
    }

    override init() {
        super.init()
        library = OfflineLibrary.loadManifest()
        // Re-adopt anything the system was still carrying from a previous run.
        Task { await reattachToRunningTasks() }
    }

    // MARK: - Queries

    func isDownloaded(_ uuid: String) -> Bool {
        library.contains { $0.uuid == uuid }
    }

    func entry(for uuid: String) -> DownloadedVideo? {
        library.first { $0.uuid == uuid }
    }

    func isDownloading(_ uuid: String) -> Bool {
        active[uuid] != nil
    }

    var totalBytes: Int { OfflineLibrary.totalBytesOnDisk(library) }

    // MARK: - Starting

    /// Begin downloading one rendition of a video.
    ///
    /// The caller picks the file, because resolution is a real choice: the
    /// difference between 1080p and 480p is often several hundred megabytes.
    @MainActor
    func download(_ details: VideoDetails, file: VideoFile, instance: Instance) {
        let uuid = details.video.uuid
        guard !isDownloaded(uuid), !isDownloading(uuid) else { return }

        // Belt and braces: the UI hides the affordance, but nothing should be
        // able to reach this with downloads disabled by the uploader.
        guard details.downloadEnabled else {
            lastError = "The uploader has disabled downloads for this video."
            return
        }

        guard let source = file.fileDownloadURL ?? file.fileURL,
              let url = URL(string: source) else {
            lastError = "This video has no downloadable file."
            return
        }

        let task = session.downloadTask(with: url)
        pendingLock.lock()
        pending[task.taskIdentifier] = PendingDownload(
            uuid: uuid,
            title: details.video.name,
            channelName: details.video.channel?.displayName
                ?? details.video.account?.displayName ?? "",
            duration: details.video.duration,
            resolutionLabel: file.displayName,
            thumbnailURL: instance.resolve(details.video.thumbnailPath),
            instanceHost: instance.host
        )
        pendingLock.unlock()

        active[uuid] = DownloadProgress(
            uuid: uuid,
            title: details.video.name,
            bytesWritten: 0,
            bytesExpected: Int64(file.size)
        )
        task.resume()
    }

    @MainActor
    func cancel(_ uuid: String) {
        active[uuid] = nil
        Task {
            let tasks = await session.allTasks
            // Locking happens inside a synchronous helper: taking a lock
            // directly in an async function risks holding it across a
            // suspension, which is why the compiler rejects it outright.
            let identifiers = takePendingIdentifiers(for: uuid)
            for task in tasks where identifiers.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
    }

    @MainActor
    func delete(_ entry: DownloadedVideo) {
        OfflineLibrary.removeFiles(for: entry)
        library.removeAll { $0.uuid == entry.uuid }
        OfflineLibrary.saveManifest(library)
    }

    @MainActor
    func deleteAll() {
        library.forEach(OfflineLibrary.removeFiles)
        library = []
        OfflineLibrary.saveManifest(library)
    }

    /// Fetch and store the poster frame, returning its filename.
    private static func storeThumbnail(from url: URL?, uuid: String,
                                       into directory: URL) async -> String? {
        guard let url,
              let image = try? await ImageLoader.shared.image(for: url),
              let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = "\(uuid).jpg"
        try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    /// After a cold launch the system may still be running transfers from a
    /// previous session; without this they complete into a manager that has no
    /// record of them and show no progress.
    private func reattachToRunningTasks() async {
        let tasks = await session.allTasks
        guard !tasks.isEmpty else { return }
        // The metadata for these was lost with the previous process. They are
        // allowed to finish — `didFinishDownloadingTo` handles a missing entry
        // by discarding the file rather than writing a library row it cannot
        // describe.
        for task in tasks where task.state == .running {
            task.resume()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        pendingLock.lock()
        let entry = pending[downloadTask.taskIdentifier]
        pendingLock.unlock()
        guard let entry else { return }

        Task { @MainActor in
            var progress = active[entry.uuid] ?? DownloadProgress(
                uuid: entry.uuid, title: entry.title, bytesWritten: 0, bytesExpected: 0
            )
            progress.bytesWritten = totalBytesWritten
            // The server's Content-Length is more trustworthy than the size the
            // API reported, which some instances leave at zero.
            if totalBytesExpectedToWrite > 0 {
                progress.bytesExpected = totalBytesExpectedToWrite
            }
            active[entry.uuid] = progress
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        pendingLock.lock()
        let entry = pending[downloadTask.taskIdentifier]
        pending[downloadTask.taskIdentifier] = nil
        pendingLock.unlock()

        // No metadata means this is an orphan from a previous process. The
        // temporary file is deleted by the system when this method returns, so
        // simply not moving it is the whole cleanup.
        guard let entry, let mediaDirectory = OfflineLibrary.mediaDirectory else { return }

        let suggestedExtension = downloadTask.originalRequest?.url?.pathExtension
        let videoExtension = (suggestedExtension?.isEmpty == false) ? suggestedExtension! : "mp4"
        let videoFilename = "\(entry.uuid).\(videoExtension)"
        let destination = mediaDirectory.appendingPathComponent(videoFilename)

        // The move has to happen synchronously, before this method returns —
        // the system deletes `location` immediately afterwards.
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in
                active[entry.uuid] = nil
                lastError = "Couldn't save the download: \(error.localizedDescription)"
            }
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size])
            .flatMap { $0 as? Int } ?? 0

        Task { [weak self] in
            guard let self else { return }
            // Keep the poster frame beside the video so the offline library
            // renders with no network at all. Computed into a `let` because a
            // `var` mutated here and read inside the MainActor hop below is a
            // capture crossing a concurrency boundary.
            let thumbnailFilename = await Self.storeThumbnail(
                from: entry.thumbnailURL, uuid: entry.uuid, into: mediaDirectory
            )

            await MainActor.run {
                let downloaded = DownloadedVideo(
                    uuid: entry.uuid,
                    title: entry.title,
                    channelName: entry.channelName,
                    durationSeconds: entry.duration,
                    resolutionLabel: entry.resolutionLabel,
                    byteSize: size,
                    downloadedAt: Date(),
                    videoFilename: videoFilename,
                    thumbnailFilename: thumbnailFilename,
                    instanceHost: entry.instanceHost
                )
                self.library.removeAll { $0.uuid == entry.uuid }
                self.library.insert(downloaded, at: 0)
                OfflineLibrary.saveManifest(self.library)
                self.active[entry.uuid] = nil
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        pendingLock.lock()
        let entry = pending[task.taskIdentifier]
        if error != nil { pending[task.taskIdentifier] = nil }
        pendingLock.unlock()
        guard let entry, let error else { return }

        let apiError = APIError.from(error)
        Task { @MainActor in
            active[entry.uuid] = nil
            // A cancellation is something the reader asked for, not a failure
            // worth reporting back to them.
            if apiError != .cancelled {
                lastError = "\(entry.title): \(apiError.message)"
            }
        }
    }

    /// The system calls this after delivering every completed transfer from a
    /// background relaunch. Handing the stored handler back is what lets iOS
    /// snapshot the UI and suspend the app again.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
