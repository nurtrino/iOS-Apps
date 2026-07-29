# iOS-Apps

Native mobile apps, one folder each. Workflows live at the repository root
because GitHub requires it, but everything else an app owns — sources, build
tooling, tests, README — stays inside that app's directory.

| App | What it is | Status |
| --- | --- | --- |
| [`pol-reader/`](pol-reader/) | Unofficial read-only client for 4chan's /pol/, built on the public JSON API. | iOS complete; Android shares the pure-logic layers with a thin Compose screen. |

## Layout

```
.github/workflows/      CI, one workflow per app
pol-reader/
  ios/                  SwiftUI app + generated Xcode project
  android/              Kotlin port + Gradle build
  tools/                project generation, icon generation, tests
  README.md             the app's own documentation
```

Each app's tooling resolves paths relative to its own folder, so
`python3 pol-reader/tools/precheck.py` works from anywhere in the tree and a
second app can bring its own toolchain without colliding.

## CI

Both workflows build on push and publish to a single rolling `latest` release.
Assets are prefixed per app, so they can share the release without clobbering
each other. See each app's README for build details and caveats.
