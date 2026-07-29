import SwiftUI

/// Full-screen image viewer with pinch-to-zoom.
struct AttachmentViewer: View {

    let board: String
    let attachment: Attachment

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteImage(url: MediaURL.file(board: board, attachment: attachment),
                        contentMode: .fit) {
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
                        if scale <= 1 {
                            resetPan()
                        }
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

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    Spacer()
                    if let url = MediaURL.file(board: board, attachment: attachment) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.4))
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
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.bottom, 24)
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
