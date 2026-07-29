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

    static func save(board: String, attachment: Attachment) async throws {
        guard attachment.isSavableToPhotos else {
            throw Failure.unsupported(attachment.ext)
        }
        guard let url = MediaURL.file(board: board, attachment: attachment) else {
            throw Failure.failed("Couldn't build a URL for this file.")
        }

        // Ask before downloading: a refused prompt should not have cost the
        // reader several megabytes of cellular data first.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw Failure.denied
        }

        let data: Data
        do {
            data = try await ImageLoader.shared.data(for: url)
        } catch {
            throw Failure.failed(ChanError.from(error).message)
        }

        // Photos reads the resource from a file, and infers the type from the
        // extension — so the temporary copy keeps the original one.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(attachment.ext.replacingOccurrences(of: ".", with: ""))
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            throw Failure.failed("Couldn't write the file to disk.")
        }
        defer { try? FileManager.default.removeItem(at: file) }

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
                request.addResource(with: resourceType, fileURL: file, options: options)
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
