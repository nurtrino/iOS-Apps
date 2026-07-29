# iOS-Apps

Native mobile apps, one folder each. Workflows live at the repository root
because GitHub requires it, but everything else an app owns — sources, build
tooling, tests, README — stays inside that app's directory.

| App | What it is | Status |
| --- | --- | --- |
| [`pol-reader/`](pol-reader/) | Unofficial read-only client for 4chan's /pol/, built on the public JSON API. | iOS complete; Android shares the pure-logic layers with a thin Compose screen. |
| [`vela/`](vela/) | Native client for PeerTube, the open federated video network — offline downloads, background audio, Picture in Picture, sign-in. | iOS. |
| [`dispatch/`](dispatch/) | News reader in four themed tabs — War, Politics, Markets, Gaming — with an on-device story classifier, live stream detection and market charts. | iOS. |

## Layout

```
.github/workflows/      CI, one workflow per app
pol-reader/
  ios/                  SwiftUI app + generated Xcode project
  android/              Kotlin port + Gradle build
  tools/                project generation, icon generation, tests
  README.md             the app's own documentation
vela/
  ios/                  SwiftUI app + generated Xcode project
  tools/                project generation, icon generation, prechecks
  README.md             the app's own documentation
dispatch/
  ios/                  SwiftUI app + generated Xcode project
  tools/                project generation, icons, prechecks, parser tests
  README.md             the app's own documentation
```

Each app's tooling resolves paths relative to its own folder, so
`python3 pol-reader/tools/precheck.py` works from anywhere in the tree and a
second app can bring its own toolchain without colliding.

## CI

Every workflow builds on push and publishes to a single rolling `latest` release.
Assets are prefixed per app, so they can share the release without clobbering
each other. See each app's README for build details and caveats.
