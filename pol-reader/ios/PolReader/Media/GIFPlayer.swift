import ImageIO
import UIKit

/// What can be told about image bytes without decoding them.
enum GIFSupport {

    /// True when the file holds more than one frame, i.e. there is an animation
    /// to play. Counting frames does not decode any of them.
    ///
    /// Worth asking rather than trusting the extension: a good share of `.gif`
    /// uploads are single-frame, and those belong on the ordinary cached-image
    /// path like any other still.
    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
}

/// Plays animated image data.
///
/// `UIImage(data:)` keeps only the *first frame* of a GIF — so every GIF in the
/// app, having gone through `ImageLoader`, was a still. That is the bug this
/// view exists to fix.
///
/// `CGAnimateImageDataWithBlock` is the system's own animator: it hands back one
/// frame at a time, on the main queue, honouring each frame's delay and the
/// file's loop count. Crucially it does not decode the whole file up front,
/// which the obvious alternative — `UIImage.animatedImage(with:duration:)` over
/// every frame — does. A few hundred frames of a full-size GIF held decoded is
/// hundreds of megabytes, which on a phone is not a slowdown but a kill.
final class GIFPlayerView: UIView {

    /// Bumped for every new file and by `stop()`. A running animation block
    /// compares it against the value it captured and ends itself when they
    /// differ — the API returns no handle on a running animation, so this
    /// counter is the only way to supersede one.
    private var generation = 0

    /// Identifies what is playing, so the ordinary re-renders of the enclosing
    /// SwiftUI view do not restart the animation from frame zero. The byte
    /// count is enough on its own: the view above is also keyed on its URL.
    private var playingKey: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The zoom and dismiss gestures belong to the views around this one; a
        // UIKit view that swallowed touches here would break both.
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GIFPlayerView is not loaded from a nib")
    }

    func play(_ data: Data) {
        guard playingKey != data.count else { return }
        playingKey = data.count
        generation += 1
        let token = generation

        // The block runs until it sets `stop`. It is called on the main queue,
        // so assigning to the layer from inside it is safe. A file that fails
        // to start simply leaves the layer empty — the caller has already
        // established that these bytes animate.
        _ = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
            guard let self, self.generation == token else {
                stop.pointee = true
                return
            }
            self.layer.contents = frame
        }
    }

    /// Ends playback and releases the frame on screen.
    func stop() {
        generation += 1
        playingKey = nil
        layer.contents = nil
    }
}
