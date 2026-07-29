import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// What is currently loaded into the player.
struct NowPlaying: Equatable {
    let video: Video
    let url: URL
    /// True when playing a downloaded file rather than streaming.
    let isOffline: Bool
}

/// The one player in the app.
///
/// A single long-lived `AVPlayer` rather than one per screen: Picture in
/// Picture, the lock screen and the mini-player all have to refer to the same
/// playback, and handing each view its own player is what makes audio double up
/// or PiP close itself the moment a view redraws.
@MainActor
final class PlayerEngine: ObservableObject {

    static let shared = PlayerEngine()

    let player = AVPlayer()

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var failureMessage: String?
    /// Whether the full-screen player is showing, as opposed to the mini-player.
    @Published var isExpanded = false
    /// Set by the PiP controller so the layer knows not to release the player
    /// when the app backgrounds.
    @Published var isPictureInPictureActive = false

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
    }

    // MARK: - Loading

    func play(_ video: Video, url: URL, isOffline: Bool) {
        // Re-tapping whatever is already loaded should resume, not restart from
        // the beginning and lose the position.
        if nowPlaying?.video.uuid == video.uuid, nowPlaying?.isOffline == isOffline {
            resume()
            return
        }

        failureMessage = nil
        teardownItemObservers()

        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        nowPlaying = NowPlaying(video: video, url: url, isOffline: isOffline)
        duration = Double(video.duration)
        currentTime = 0

        // The session is activated per playback rather than once at launch, so
        // simply having the app open does not interrupt someone else's audio.
        activateAudioSession()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        loadArtwork(for: video)
    }

    func resume() {
        guard nowPlaying != nil else { return }
        activateAudioSession()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func stop() {
        pause()
        teardownItemObservers()
        player.replaceCurrentItem(with: nil)
        nowPlaying = nil
        isExpanded = false
        currentTime = 0
        duration = 0
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        updateNowPlayingInfo()
    }

    func skip(by delta: Double) {
        seek(to: min(max(0, currentTime + delta), duration > 0 ? duration : .greatestFiniteMagnitude))
    }

    // MARK: - Audio session

    /// `.playback` is what allows audio to continue with the screen locked and
    /// the app in the background. Paired with the `audio` background mode in
    /// Info.plist — without both, iOS silences the app the moment it leaves the
    /// foreground.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .moviePlayback, options: []
        )
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Observation

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let itemDuration = self.player.currentItem?.duration.seconds,
               itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
            // Cheap enough at 2 Hz, and it keeps the lock-screen scrubber from
            // drifting away from the real position.
            self.updateNowPlayingElapsed()
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "This video couldn't be played."
            Task { @MainActor [weak self] in
                self?.failureMessage = reason
                self?.isPlaying = false
            }
        }

        bufferObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) {
            [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.isBuffering = !item.isPlaybackLikelyToKeepUp
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func teardownItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        bufferObservation?.invalidate()
        bufferObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    // MARK: - Lock screen and remote controls

    /// Without these the lock screen shows a dead pane and the headphone button
    /// does nothing, which is most of what "background playback" means to
    /// somebody actually using it.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let nowPlaying else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = nowPlaying.video.name
        info[MPMediaItemPropertyArtist] =
            nowPlaying.video.channel?.displayName ?? nowPlaying.video.account?.displayName ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = nowPlaying.video.isLive
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Only the moving parts, so the twice-a-second update does not rebuild the
    /// artwork entry.
    private func updateNowPlayingElapsed() {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for video: Video) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let instance = await PeerTubeAPI.shared.currentInstance()
            guard let url = instance?.resolve(video.thumbnailPath),
                  let image = try? await ImageLoader.shared.image(for: url) else { return }
            guard !Task.isCancelled, self.nowPlaying?.video.uuid == video.uuid else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
