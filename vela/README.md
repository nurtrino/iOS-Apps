# Vela

A native iOS client for [PeerTube](https://joinpeertube.org), the open
federated video network.

Offline downloads, background audio, Picture in Picture and sign-in — all of
them working *with* the platform rather than around it. PeerTube serves no ads,
publishes a documented API with real OAuth, and exposes a download URL per video
gated by the uploader's own consent flag. So none of this is a workaround, which
is also the reason it should keep working.

## Features

| | |
| --- | --- |
| **No ads** | Not a feature so much as a property — PeerTube has no ad system to strip. |
| **Offline downloads** | Background `URLSession`, so transfers survive the app being suspended. Files stay in the app and play with no connection. |
| **Save to Photos** | Exports a downloaded file to the system library, using add-only permission. |
| **Background audio** | Keeps playing with the screen locked, with lock-screen controls and artwork. |
| **Picture in Picture** | Starts automatically when you leave the app from an inline video. |
| **Sign in** | PeerTube's own OAuth password grant. Tokens live in the Keychain; the password is never stored. |

Sign-in is optional throughout. PeerTube serves its catalogue anonymously, so an
account buys a subscriptions feed — not access.

## The two details that matter most

**Background video is not background audio.** iOS tears down the video pipeline
when an app with an attached `AVPlayerLayer` backgrounds, and playback stops —
audio included. `PlayerContainerView` releases the player from the layer on the
way out and repopulates it on the way back, which leaves an audio-only pipeline
that the `audio` background mode keeps alive. It deliberately skips this while
PiP is active, where the layer is exactly what PiP renders from and detaching it
closes the window.

**`downloadEnabled` is per video.** PeerTube lets each uploader decide whether
their video may be downloaded, and exposes that as a flag. The download
affordance is hidden when it is false, and `DownloadManager` refuses regardless
of what the UI did. The point of a consent flag is that it is honoured.

## Layout

```
ios/Vela/
  Model/      Video, VideoFile, Channel, Page — lenient decoding
  Net/        instance resolution, paginated API client, error mapping
  Auth/       OAuth, Keychain token storage, refresh rotation
  Playback/   AVPlayer engine, PiP, lock-screen controls
  Download/   background URLSession, on-disk offline library
  Media/      image loading, Photos export
  Data/       stores: feeds, detail, settings
  UI/         SwiftUI screens, docked mini-player
tools/        project generation, icon generation, prechecks
```

## Federation

PeerTube is not one server. The instance is a runtime choice — pick one in
Settings or type any host. Switching signs you out, because an account belongs
to the instance that issued it, and every relative path the API returns resolves
against whichever instance answered.

## Building

There is no Xcode or Swift toolchain in the development environment, so **CI is
the compiler**. Before pushing:

```
python3 vela/tools/precheck.py          # balance, placeholders, plist, project
python3 vela/tools/gen_pbxproj.py       # regenerate the project from disk
python3 vela/tools/make_icons.py        # regenerate the app icon
```

`precheck` leans hard on `Info.plist`, because the capabilities this app is
built around fail *silently* without it: omit `UIBackgroundModes: audio` and the
build still succeeds, the code still runs, and audio just stops the moment the
app backgrounds. The CI job re-asserts both keys against the built `.app`, not
only the source.

## Known limitations

- **The API was never reached from this environment.** Egress policy blocks
  PeerTube instances, so the models are built against the published OpenAPI
  spec (v8.1.0) rather than live responses.
- **Compiling is not running.** CI proves it builds and packages. Background
  playback, PiP and Photos export are exactly the features that only really
  prove out on hardware.
- **HLS downloads.** Instances serving only HLS expose per-resolution files that
  download as a single file; an instance offering neither progressive files nor
  per-resolution HLS files will show no download option.
