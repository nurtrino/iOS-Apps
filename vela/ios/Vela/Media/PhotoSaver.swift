import Photos
import UIKit

/// Copies a downloaded video into the system photo library.
///
/// Add-only authorisation (`.addOnly`) rather than full access: saving needs
/// permission to write, and asking to *read* somebody's entire photo library in
/// order to write one file is a request that should not be made. iOS shows a
/// noticeably lighter prompt for it.
enum PhotoSaver {

    enum SaveError: LocalizedError {
        case permissionDenied
        case fileMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Vela needs permission to add to your photo library. You can grant it in Settings."
            case .fileMissing:
                return "That download is no longer on disk."
            case .failed(let reason):
                return reason
            }
        }
    }

    static func save(fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SaveError.fileMissing
        }

        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
