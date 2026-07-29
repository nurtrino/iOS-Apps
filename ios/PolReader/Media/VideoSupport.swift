import AVFoundation
import Foundation

/// What this device can actually play, and how.
///
/// 4chan's video is overwhelmingly WebM (VP8/VP9), which is precisely the one
/// container AVFoundation has never decoded — on any iOS version, including
/// current ones. There is no `AVPlayer` path for it and no amount of
/// configuration changes that.
///
/// WebKit is a different engine with a different codec set, and it *did* gain
/// WebM `<video>` playback — in **iOS 17.4**. Earlier releases advertise VP8 and
/// VP9 only for WebRTC, which does not help a file in a `<video>` tag. So:
///
///   - `.mp4` / `.m4v` / `.mov` → `AVPlayer`, everywhere, with real controls,
///     Picture in Picture and background audio.
///   - `.webm` → `WKWebView` on iOS 17.4 and later.
///   - `.webm` below 17.4 → nothing in-process can decode it. The UI says so
///     and offers the browser, rather than presenting a player that will sit
///     there black.
///
/// The alternative — bundling a software decoder such as VLCKit or libvpx —
/// would work on every version, at the cost of tens of megabytes of binary
/// framework that cannot be verified from this build environment. That trade is
/// deliberately not taken here; the note above is what to revisit if it should be.
enum VideoSupport {

    /// Whether WebKit on this device can decode a WebM file in a `<video>` tag.
    static var playsWebM: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    enum Backend: Equatable {
        /// AVFoundation can decode it.
        case native
        /// WebKit can decode it; AVFoundation cannot.
        case web
        /// Nothing on this device can. Carries the reason to show the reader.
        case unsupported(String)
    }

    static func backend(for attachment: Attachment) -> Backend {
        if attachment.isNativelyPlayable { return .native }
        if attachment.isWebM {
            return playsWebM
                ? .web
                : .unsupported("WebM playback needs iOS 17.4 or later. Open in the browser instead.")
        }
        return .unsupported("This file type can't be played in the app.")
    }

    /// Route audio to the speaker even when the ringer switch is silenced, and
    /// let it mix rather than stopping whatever else is playing.
    ///
    /// Without this, tapping a video on a phone that is on silent plays a
    /// completely silent clip, which reads as a bug rather than as a setting.
    static func activatePlaybackAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    /// Hand audio focus back when the viewer closes.
    static func deactivatePlaybackAudio() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}
