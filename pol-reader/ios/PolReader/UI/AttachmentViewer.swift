import SwiftUI
import UIKit

/// Full-screen viewer for a post's attachment.
///
/// One presentation for both media kinds so expanding always feels the same:
/// images get pinch-and-double-tap zoom, GIFs play, video gets a player. The
/// chrome, the swipe-to-close gesture, the save action and the share
/// affordance are shared.
struct AttachmentViewer: View {

    let board: String
    let attachment: Attachment

    @Environment(\.dismiss) private var dismiss
    @State private var externalLink: ExternalLink?

    /// How far the media has been dragged down by the close gesture.
    @State private var dragOffset: CGFloat = 0
    /// True while an image is pinched in. Panning a zoomed image and swiping to
    /// close are the same finger movement, so only one of them may be live.
    @State private var isZoomed = false

    @State private var isSaving = false
    @State private var didSave = false
    @State private var saveError: String?

    /// Let go past this and the viewer closes.
    private let dismissDistance: CGFloat = 120

    /// 0 at rest, 1 once the drag is unambiguous. Drives the shrink and the
    /// chrome fade, so the gesture reads as "peeling this off" well before the
    /// finger lifts.
    private var dragProgress: CGFloat {
        min(1, max(0, dragOffset / (dismissDistance * 1.6)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            media
                .scaleEffect(1 - dragProgress * 0.12)
                .offset(y: dragOffset)

            chrome
                .opacity(1 - dragProgress)
        }
        // The close swipe is a UIKit recognizer rather than a `DragGesture` —
        // see `SwipeDownToDismiss` for why the players make that necessary.
        .background(
            SwipeDownToDismiss(
                isEnabled: !isZoomed,
                onChanged: { translation in
                    dragOffset = max(0, translation)
                },
                onEnded: { translation, velocity in
                    // A flick counts as well as a long drag: matching only on
                    // distance makes a fast swipe feel like it was ignored.
                    if translation > dismissDistance || (velocity > 900 && translation > 24) {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                }
            )
        )
        .sheet(item: $externalLink) { link in
            SafariSheet(url: link.url)
        }
        .alert(
            "Couldn't Save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            ),
            presenting: saveError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var media: some View {
        if attachment.isVideo {
            VideoPlayerView(board: board, attachment: attachment) { _ in
                if let url = MediaURL.file(board: board, attachment: attachment) {
                    externalLink = ExternalLink(url: url)
                }
            }
            .ignoresSafeArea()
        } else {
            Zoomable(isZoomed: $isZoomed) {
                if attachment.isAnimatedGIF {
                    RemoteAnimatedImage(
                        url: MediaURL.file(board: board, attachment: attachment),
                        contentMode: .fit
                    ) {
                        ProgressView().tint(.white)
                    }
                } else {
                    RemoteImage(
                        url: MediaURL.file(board: board, attachment: attachment),
                        contentMode: .fit
                    ) {
                        ProgressView().tint(.white)
                    }
                }
            }
        }
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    glyph("xmark.circle.fill")
                }
                Spacer()
                saveButton
                if let url = MediaURL.file(board: board, attachment: attachment) {
                    ShareLink(item: url) {
                        glyph("square.and.arrow.up.circle.fill")
                    }
                }
            }
            .padding()

            Spacer()

            VStack(spacing: 2) {
                if didSave {
                    Text("Saved to Photos")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
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

    @ViewBuilder
    private var saveButton: some View {
        // Shown for every file, including the ones Photos will refuse. Hiding
        // it there would read as the app having forgotten how to save that
        // post; the refusal comes back as a sentence that says which format it
        // is and what to do instead.
        Button(action: save) {
            ZStack {
                glyph(didSave ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .opacity(isSaving ? 0 : 1)
                if isSaving {
                    ProgressView().tint(.white)
                }
            }
        }
        .disabled(isSaving)
        .accessibilityLabel("Save to Photos")
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.45))
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                try await MediaSaver.save(board: board, attachment: attachment)
                isSaving = false
                withAnimation { didSave = true }
                // Long enough to read, short enough that it is gone before the
                // next thing the reader does.
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { didSave = false }
            } catch {
                isSaving = false
                saveError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

/// Pinch, pan and double-tap zoom over whatever the viewer is showing.
///
/// Generic over its content because a GIF is played by a different view than a
/// still image, and the zoom behaviour should not care which it is.
private struct Zoomable<Content: View>: View {

    /// Reported upward so the viewer can stand its close gesture down: a drag
    /// on a zoomed image means "pan", not "close".
    @Binding var isZoomed: Bool
    @ViewBuilder var content: () -> Content

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        content()
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
            .onChange(of: scale) { value in
                // Only on the crossing: a pinch changes `scale` every frame,
                // and each write up the binding re-renders the whole viewer.
                let zoomed = value > 1.001
                if zoomed != isZoomed { isZoomed = zoomed }
            }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}

/// A downward swipe anywhere in the viewer, including over the players.
///
/// A SwiftUI `DragGesture` is not enough here. `AVPlayerViewController` and
/// `WKWebView` bring their own gesture recognizers, and a SwiftUI gesture
/// attached to an ancestor loses the arbitration to them — which would leave
/// swipe-to-close working over a still image and doing nothing over a video.
/// That is worse than not having it at all.
///
/// A `UIPanGestureRecognizer` sits *alongside* those recognizers instead of
/// competing with them: `cancelsTouchesInView` stays false and the delegate
/// allows simultaneous recognition, so the scrubber and the play button keep
/// working while the swipe is still seen.
///
/// It attaches to the enclosing view controller's view rather than to the
/// window, which is the tempting shortcut. The share sheet presents into the
/// same window; a recognizer up there would let a swipe meant for the sheet
/// drag the viewer around underneath it.
private struct SwipeDownToDismiss: UIViewRepresentable {

    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostAwareView()
        view.isUserInteractionEnabled = false
        view.onHostChange = { [coordinator = context.coordinator] host in
            coordinator.attach(to: host)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        // Disabling mid-gesture cancels it, which is exactly what should happen
        // when a pinch turns the image into something pannable.
        context.coordinator.pan.isEnabled = isEnabled
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

        private(set) lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            return pan
        }()

        func attach(to host: UIView?) {
            guard host !== pan.view else { return }
            pan.view?.removeGestureRecognizer(pan)
            host?.addGestureRecognizer(pan)
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: pan.view).y
            switch pan.state {
            case .changed:
                onChanged(translation)
            case .ended:
                onEnded(translation, pan.velocity(in: pan.view).y)
            case .cancelled, .failed:
                onEnded(0, 0)
            default:
                break
            }
        }

        /// Only downward, mostly-vertical drags. Without this the recognizer
        /// fires on a horizontal swipe across a zoomed-out image and on the
        /// upward half of a scrub.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// Reports the view controller it ends up inside, once it is in a window.
    private final class HostAwareView: UIView {

        var onHostChange: ((UIView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onHostChange?(window == nil ? nil : enclosingControllerView)
        }

        private var enclosingControllerView: UIView? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller.view }
                responder = next
            }
            return nil
        }
    }
}
