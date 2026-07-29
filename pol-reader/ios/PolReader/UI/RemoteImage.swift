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
        if let cached = await ImageLoader.shared.cached(url) {
            image = cached
            failed = false
            return
        }
        // Reset so a changed URL does not leave the previous image showing
        // while the new one is in flight.
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

/// A post's attached media, as it appears inline in a list.
///
/// Media loads on sight. Reading a thread should not be a sequence of taps to
/// find out what is in it, so the only thing a tap does here is expand — the
/// blur and hide modes are settings for people who want them, not the default
/// path.
struct PostThumbnail: View {

    /// How much room the media takes.
    enum Layout: Equatable {
        /// Fixed square, cropped to fill. Used beside a reply's metadata.
        case square(CGFloat)
        /// Full available width, height from the real aspect ratio and capped.
        /// Used for a thread's main image, which is usually the point of it.
        case fill(maxHeight: CGFloat)
    }

    let board: String
    let attachment: Attachment
    let mode: ThumbnailMode
    var revealSpoilers: Bool = true
    var layout: Layout = .square(96)
    /// Pull the original file rather than the CDN thumbnail.
    ///
    /// Kept separate from `layout` on purpose: the catalog wants big
    /// aspect-correct cells but must *not* fetch 150 full-size images to draw
    /// one screen. Only a thread's own main image earns the full download.
    var useFullImage: Bool = false
    /// Whether a tap here may reveal a concealed image.
    ///
    /// False wherever the surrounding view owns the tap — the catalog, where
    /// tapping a thread's image means "open the thread". Without this, turning
    /// on blur mode would bring back the bug where the image ate the tap and
    /// only the title navigated.
    var allowsReveal: Bool = true

    @State private var revealed = false

    private var isHidden: Bool { mode == .hide && !revealed }

    private var isBlurred: Bool {
        guard !revealed else { return false }
        if mode == .blur { return true }
        return attachment.isSpoiler && !revealSpoilers
    }

    private var sourceURL: URL? {
        if useFullImage, attachment.isDisplayableImage, !attachment.isDeleted {
            return MediaURL.file(board: board, attachment: attachment)
        }
        return MediaURL.thumbnail(board: board, attachment: attachment)
    }

    private var aspectRatio: Double {
        attachment.thumbAspectRatio > 0 ? attachment.thumbAspectRatio : 1
    }

    private var isFill: Bool {
        if case .fill = layout { return true }
        return false
    }

    /// True only while a tap here would actually do something locally.
    private var needsRevealTap: Bool { allowsReveal && (isHidden || isBlurred) }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: isFill ? 10 : 6))
            .overlay(alignment: .bottomLeading) { badge }
            // Keeps the whole frame hit-testable so the parent's tap target
            // covers the image, including any transparent regions.
            .contentShape(Rectangle())
            // The reveal gesture is *masked off* rather than conditionally
            // attached. Two things this gets right:
            //
            // Attaching it unconditionally and testing the condition inside the
            // closure — which is what this used to do — still consumes every
            // tap. With media loading by default there is nothing to reveal, so
            // the image ate the tap and neither the catalog's NavigationLink
            // nor the thread's expand action ever fired.
            //
            // Branching in `body` instead would fix that but swap the subtree,
            // which resets `RemoteImage`'s state and makes the picture reload
            // the moment you reveal it. A gesture mask leaves the tree alone.
            .gesture(
                TapGesture().onEnded { revealed = true },
                including: needsRevealTap ? .all : .subviews
            )
    }

    @ViewBuilder
    private var content: some View {
        if isHidden {
            sized { placeholder(systemImage: "eye.slash", label: "Not loaded") }
        } else if attachment.isDeleted {
            sized { placeholder(systemImage: "trash", label: "File deleted") }
        } else {
            switch layout {
            case .square(let side):
                RemoteImage(url: sourceURL)
                    .frame(width: side, height: side)
                    .blur(radius: isBlurred ? 14 : 0)
                    .clipped()

            case .fill(let maxHeight):
                RemoteImage(url: sourceURL, contentMode: .fit)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .blur(radius: isBlurred ? 26 : 0)
            }
        }
    }

    @ViewBuilder
    private func sized<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch layout {
        case .square(let side):
            content().frame(width: side, height: side)
        case .fill:
            content().frame(maxWidth: .infinity).frame(height: 140)
        }
    }

    /// Video gets a play glyph and its container named, so it is obvious before
    /// tapping that this is a clip and which format it is.
    @ViewBuilder
    private var badge: some View {
        if attachment.isVideo && !isHidden {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: isFill ? 11 : 8))
                Text(attachment.ext.dropFirst().uppercased())
                    .font(.system(size: isFill ? 10 : 8, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6))
            .clipShape(Capsule())
            .padding(5)
        } else if isBlurred {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.5), in: Circle())
                .padding(5)
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
