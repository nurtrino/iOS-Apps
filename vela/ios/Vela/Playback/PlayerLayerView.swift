import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// The video surface, plus Picture in Picture.
///
/// An `AVPlayerLayer` rather than SwiftUI's `VideoPlayer` because
/// `AVPictureInPictureController` has to be constructed from a layer, and
/// because the layer is what has to be detached to keep audio alive in the
/// background. `VideoPlayer` exposes neither.
struct PlayerLayerView: UIViewRepresentable {

    let player: AVPlayer
    @ObservedObject var engine: PlayerEngine

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.attach(player: player, engine: engine)
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.attach(player: player, engine: engine)
    }

    static func dismantleUIView(_ view: PlayerContainerView, coordinator: ()) {
        view.detachForTeardown()
    }
}

/// Hosts the player layer and owns the PiP controller.
final class PlayerContainerView: UIView {

    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var pipController: AVPictureInPictureController?
    private weak var engine: PlayerEngine?
    private var observers: [NSObjectProtocol] = []
    /// Held across a background transition so the layer can be repopulated.
    private var detachedPlayer: AVPlayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        observeLifecycle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        observeLifecycle()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(player: AVPlayer, engine: PlayerEngine) {
        self.engine = engine
        if playerLayer.player !== player, detachedPlayer == nil {
            playerLayer.player = player
        }
        setUpPictureInPictureIfNeeded()
    }

    func detachForTeardown() {
        playerLayer.player = nil
        detachedPlayer = nil
    }

    // MARK: - Picture in Picture

    private func setUpPictureInPictureIfNeeded() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        // Hands off to PiP automatically when the app is backgrounded from an
        // inline video, which is the behaviour people expect from a video app
        // rather than having to press a button on the way out.
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.delegate = self
        pipController = controller
    }

    func startPictureInPicture() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    var isPictureInPicturePossible: Bool {
        pipController?.isPictureInPicturePossible ?? false
    }

    // MARK: - Background transitions

    /// The reason background audio works at all.
    ///
    /// iOS tears down the video pipeline when an app with an attached
    /// `AVPlayerLayer` goes to the background, and playback stops — audio
    /// included. Releasing the player from the layer on the way out leaves an
    /// audio-only pipeline, which the `audio` background mode keeps alive; the
    /// layer is repopulated on the way back in.
    ///
    /// Skipped entirely while PiP is active, where the layer is exactly what
    /// PiP is rendering from and detaching it closes the window.
    private func observeLifecycle() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.pipController?.isPictureInPictureActive == true { return }
            self.detachedPlayer = self.playerLayer.player
            self.playerLayer.player = nil
        })

        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let detached = self.detachedPlayer else { return }
            self.playerLayer.player = detached
            self.detachedPlayer = nil
        })
    }
}

extension PlayerContainerView: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        engine?.isPictureInPictureActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        engine?.isPictureInPictureActive = false
    }

    /// Called when someone taps the PiP window to come back to the app. Without
    /// implementing this the window closes and playback is orphaned rather than
    /// returning to the full-screen player.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        engine?.isExpanded = true
        completionHandler(true)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        engine?.isPictureInPictureActive = false
    }
}
