import SwiftUI

/// An image loaded through `ImageLoader`.
///
/// Note `.task(id: url)`. Without the `id`, swapping a different URL into the
/// same position in the view hierarchy leaves the view's *identity* unchanged,
/// so the task never re-runs and the old image stays on screen forever —
/// visible as a grid where every cell shows the wrong picture after a refresh.
struct RemoteImage<Placeholder: View>: View {

    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            failed = true
            return
        }
        // Reset so a changed URL does not leave the previous image showing
        // while the new one is in flight.
        if let cached = await ImageLoader.shared.cached(url) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        do {
            let loaded = try await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

extension RemoteImage where Placeholder == AnyView {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) {
            AnyView(Color.secondary.opacity(0.12))
        }
    }
}

/// A post's thumbnail, honouring the spoiler flag and the reader's image
/// setting.
///
/// A spoilered or hidden image is never requested at all — not blurred after
/// the fact — so choosing "Hide entirely" also means the bytes are not fetched.
struct PostThumbnail: View {

    let board: String
    let attachment: Attachment
    let mode: ThumbnailMode
    var size: CGFloat = 90
    @State private var revealed = false

    private var isConcealed: Bool {
        if revealed { return false }
        return mode == .blur || attachment.isSpoiler
    }

    var body: some View {
        Group {
            if mode == .hide && !revealed {
                placeholder(systemImage: "eye.slash", label: "Image hidden")
            } else if attachment.isDeleted {
                placeholder(systemImage: "trash", label: "File deleted")
            } else if isConcealed {
                ZStack {
                    Color.secondary.opacity(0.18)
                    VStack(spacing: 4) {
                        Image(systemName: attachment.isSpoiler ? "eye.slash.circle" : "eye.circle")
                        Text(attachment.isSpoiler ? "Spoiler" : "Tap")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                RemoteImage(url: MediaURL.thumbnail(board: board, attachment: attachment))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if isConcealed || (mode == .hide && !revealed) {
                revealed = true
            }
        }
    }

    private func placeholder(systemImage: String, label: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.12)
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(label).font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// A country or board flag.
///
/// /pol/ is the board where these carry the most weight: it shows a geolocated
/// country flag by default, and lets posters swap it for one of a set of board
/// flags, which live at a different CDN path entirely.
struct FlagBadge: View {
    let board: String
    let post: Post

    private var url: URL? {
        if let boardFlag = post.boardFlag {
            return MediaURL.boardFlag(board: board, code: boardFlag)
        }
        if let country = post.country {
            return MediaURL.countryFlag(country)
        }
        return nil
    }

    private var label: String? {
        post.flagName ?? post.countryName
    }

    var body: some View {
        if let url {
            RemoteImage(url: url, contentMode: .fit)
                .frame(width: 16, height: 11)
                .accessibilityLabel(label ?? "Flag")
        }
    }
}
