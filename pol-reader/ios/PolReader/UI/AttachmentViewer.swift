import SwiftUI

/// Full-screen viewer for a post's attachment.
///
/// One presentation for both media kinds so expanding always feels the same:
/// images get pinch-and-double-tap zoom, video gets a player. The chrome, the
/// dismiss gesture and the share affordance are shared.
struct AttachmentViewer: View {

    let board: String
    let attachment: Attachment

    @Environment(\.dismiss) private var dismiss
    @State private var externalLink: ExternalLink?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if attachment.isVideo {
                VideoPlayerView(board: board, attachment: attachment) { _ in
                    if let url = MediaURL.file(board: board, attachment: attachment) {
                        externalLink = ExternalLink(url: url)
                    }
                }
                .ignoresSafeArea()
            } else {
                ZoomableImage(url: MediaURL.file(board: board, attachment: attachment))
            }

            chrome
        }
        .sheet(item: $externalLink) { link in
            SafariSheet(url: link.url)
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                Spacer()
                if let url = MediaURL.file(board: board, attachment: attachment) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                }
            }
            .padding()

            Spacer()

            VStack(spacing: 2) {
                Text(attachment.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.dimensionsText) · \(attachment.formattedFileSize)")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.bottom, 24)
            // The player owns the bottom of the screen; keep taps out of its
            // scrubber.
            .allowsHitTesting(false)
        }
    }
}

/// Pinch, pan and double-tap zoom over a remote image.
private struct ZoomableImage: View {

    let url: URL?

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        RemoteImage(url: url, contentMode: .fit) {
            ProgressView().tint(.white)
        }
        .scaleEffect(scale)
        .offset(offset)
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = max(1, min(6, committedScale * value))
                }
                .onEnded { _ in
                    committedScale = scale
                    if scale <= 1 { resetPan() }
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in committedOffset = offset }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if scale > 1 {
                    scale = 1
                    committedScale = 1
                    resetPan()
                } else {
                    scale = 2.5
                    committedScale = 2.5
                }
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
