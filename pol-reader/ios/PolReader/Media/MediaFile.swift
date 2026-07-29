import Foundation

/// A copy of a post's file on disk.
///
/// The share sheet and the photo library both want a *file*, not a link.
/// Sharing `https://i.4cdn.org/pol/1690000000000.jpg` offers Copy Link and Add
/// to Reading List; sharing the file those bytes came from offers Save Image,
/// Save Video and Save to Files. The download is identical — the whole
/// difference is in what iOS is then willing to do with it.
enum MediaFile {

    /// Fetches the attachment through the media cache and writes it to a
    /// temporary file named as it was uploaded.
    ///
    /// The caller owns the result and should hand it back to `discard` when
    /// done with it.
    static func fetch(board: String, attachment: Attachment) async throws -> URL {
        guard let url = MediaURL.file(board: board, attachment: attachment) else {
            throw ChanError.notFound
        }
        let data = try await ImageLoader.shared.data(for: url)

        // A directory per copy. The file inside can then keep the poster's own
        // filename — which is what the share sheet and Photos show — without
        // two copies of one upload, or two uploads with one name, colliding.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appendingPathComponent(filename(for: attachment))
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Removes a copy handed out by `fetch`, along with the directory holding it.
    static func discard(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// The upload's own name, made safe to use as a path component.
    ///
    /// 4chan filenames are attacker-controlled text that the API hands over
    /// verbatim. A `/` in one would write outside the directory just created
    /// for it, and a name of nothing but dots is not a filename at all — both
    /// fall back to the upload timestamp, which is what actually addresses the
    /// file anyway.
    private static func filename(for attachment: Attachment) -> String {
        let cleaned = attachment.originalName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = cleaned.isEmpty || cleaned.allSatisfy { $0 == "." }
            ? String(attachment.tim)
            : cleaned
        return String(usable.prefix(60)) + attachment.ext
    }
}
