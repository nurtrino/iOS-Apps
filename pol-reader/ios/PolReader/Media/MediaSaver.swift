import Foundation
import Photos

/// Writes a post's file into the user's photo library.
///
/// The file is added as a *resource* from the original bytes rather than by
/// handing Photos a `UIImage`. Two things depend on that: an animated GIF stays
/// animated (a `UIImage` is one frame, and even an animated one would be
/// re-encoded), and nothing is silently recompressed on the way in.
enum MediaSaver {

    enum Failure: LocalizedError, Equatable {
        /// Permission was refused, or has been refused before and not changed.
        case denied
        /// A container the photo library will not accept — WebM, in practice.
        case unsupported(String)
        /// The file could not be fetched or written.
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Pol Reader isn't allowed to add to your photo library. "
                    + "You can change that in Settings › Privacy › Photos."
            case .unsupported(let ext):
                let name = ext.replacingOccurrences(of: ".", with: "").uppercased()
                return "Photos can't store \(name) files. Use Share to save it elsewhere."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// - Parameter file: A copy already on disk, if the caller has one. The
    ///   viewer does, having fetched it for the share sheet, so saving from
    ///   there costs no second download.
    static func save(board: String, attachment: Attachment, file: URL? = nil) async throws {
        guard attachment.isSavableToPhotos else {
            throw Failure.unsupported(attachment.ext)
        }

        // Ask before downloading: a refused prompt should not have cost the
        // reader several megabytes of cellular data first.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw Failure.denied
        }

        // Photos reads the resource from a file and infers the type from its
        // extension, so the copy keeps the original name and extension.
        let local: URL
        let ownsFile: Bool
        if let file {
            local = file
            ownsFile = false
        } else {
            do {
                local = try await MediaFile.fetch(board: board, attachment: attachment)
            } catch {
                throw Failure.failed(ChanError.from(error).message)
            }
            ownsFile = true
        }
        defer { if ownsFile { MediaFile.discard(local) } }

        let resourceType: PHAssetResourceType = attachment.isVideo ? .video : .photo
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // The library copies the file; we own the temporary one and
                // delete it ourselves above, which keeps the ownership rule in
                // one place instead of two.
                options.shouldMoveFile = false
                options.originalFilename = attachment.displayName
                request.addResource(with: resourceType, fileURL: local, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: Failure.failed(
                            error?.localizedDescription ?? "Photos wouldn't accept this file."
                        )
                    )
                }
            }
        }
    }
}
