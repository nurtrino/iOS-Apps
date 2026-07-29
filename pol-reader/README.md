# /pol/ reader

An unofficial, **read-only** native client for 4chan's /pol/, built on the
public read-only JSON API at `a.4cdn.org`.

Read-only is a property of the API, not a late product compromise: 4chan
publishes no write endpoint, so there is nothing to post, reply or vote with.
Anything requiring an account links out to the website.

Not affiliated with 4chan.

> **About the board.** /pol/ is anonymous, effectively unmoderated, and
> routinely contains graphic imagery and extreme content. The app shows the
> board as it is. Images are blurred by default, hidden images are never
> downloaded, and a filter list is available in Settings.

---

## What shipped

| | |
| --- | --- |
| **iOS** | Complete SwiftUI app — catalog, threads, images, watching, filters, settings. Built by CI into an unsigned `.ipa`. |
| **Android** | Shared pure-logic layers transliterated to Kotlin — parser, thread index, lenient model parsing, paced API client — plus a thin Compose catalog screen that exercises the stack end to end. Gradle and CI wired; the full screen set is the follow-up. |

## How 4chan's API shaped this

The [documented API](https://github.com/4chan/4chan-API) answers the questions
that decide a forum client's architecture, and it answers two of them unusually
well:

**A whole thread arrives in one request.** `/{board}/thread/{no}.json` returns
every post. There is no per-comment fetch to batch, no search index to fall back
from, and no partially-loaded thread state to model. Most of the machinery a
threaded-forum client normally needs simply isn't here.

**Threads are flat.** The JSON is an array in posting order; replies exist only
as `>>123` quotelinks inside the comment HTML. So the structural work is the
inverse of the usual: there is no tree to flatten on arrival, there is a
**backlink index to build** — the API does not tell you who replied to a post,
and that index is what makes reply badges and navigation possible at all. A
tree is *derived* from quotelinks for the optional threaded view.

**Rate limits are the scarce resource, not sockets.** The documentation asks for
no more than one request per second, thread updates no more often than every ten
seconds, and `If-Modified-Since` on every request. So the network layer is built
around a request pacer and a conditional-request cache rather than the usual
bounded-concurrency batch fetcher.

## Layout

```
ios/PolReader/
  Model/      Post, Board, catalog and thread responses, lenient decoding
  Net/        a.4cdn.org client, rate pacer, error mapping, CDN URL builders
  Text/       comment HTML → renderable blocks        ← most intricate, most reusable
  Thread/     backlink index, derived tree, outline operations
  Data/       stores: catalog, thread, settings, library, filters
  Media/      image loading and caching, GIF playback, saving to Photos
  UI/         SwiftUI screens                         ← the only platform-specific half
tools/        project generation, icon generation, parser and thread tests
```

`Model/`, `Text/` and `Thread/` import no UI framework. They are the parts most
worth testing in isolation and the parts that port to Kotlin unchanged.

## The comment parser

4chan emits a small HTML subset — `<br>`, `<span class="quote">` greentext,
`<a class="quotelink">`, `<s>` spoilers, `<pre>` code, `<wbr>`, entities. Every
platform HTML renderer is wrong for it: a `WebView` per comment is enormous and
unstyleable, and `NSAttributedString(documentType: .html)` pulls in WebKit,
blocks the main thread, and loses code blocks.

So it's a hand-written parser emitting **blocks**, not one string — a code block
scrolls horizontally on its own, which a single attributed string cannot express.

It is written twice: once in Swift, once in Python
(`tools/comment_parser_reference.py`) where it can actually be run. There is no
Swift toolchain in the build environment, so the Python version is where the
algorithm is proven before transliteration.

```
python3 tools/test_parser.py     # 73 assertions
python3 tools/test_thread.py     # 32 assertions
python3 tools/precheck.py        # the above, plus balance/placeholder/project checks
```

The parser tests cover the things that cost real time: entity decoding including
numeric and hex forms, span offsets surviving whitespace trimming, `javascript:`
hrefs producing no link, `<wbr>` vanishing without corrupting a URL, and a stray
`<` in prose not being read as a tag.

The thread tests cover the cycle guard — two posters quoting each other is
ordinary on 4chan, and a naive "first quotelink is the parent" rule builds an
infinite loop out of it.

## Building

There is no Xcode, Swift, or Android toolchain in the development environment.
**CI is the compiler.** Before pushing, `tools/precheck.py` catches the class of
mistake that would otherwise waste a round trip; it proves nothing about whether
the code compiles.

The Xcode project is generated, not hand-maintained:

```
python3 tools/gen_pbxproj.py            # regenerate from what is on disk
python3 tools/gen_pbxproj.py --check    # assert the committed project matches
```

Generating the file list from the directory removes a nasty failure mode: a
source file present on disk but absent from the project is silently not
compiled, and surfaces much later as an undefined symbol pointing at the use
rather than the omission.

Icons are generated procedurally (`tools/make_icons.py`) — no image libraries
are available, so the PNG encoder and rasteriser are in the script. The two
platforms want opposite things from the same artwork: iOS needs 1024×1024 RGB
with **no alpha** and full-bleed, because it applies its own mask; Android needs
a transparent foreground that stays inside the centre ~66% safe zone, which the
script asserts rather than assumes.

## Distribution

Both workflows publish to one rolling `latest` release: an **unsigned** `.ipa`
and a **debug-signed** `.apk`. Release assets, not workflow artifacts — an
artifact is wrapped in a second zip and can't be downloaded from the GitHub
mobile app. Because two workflows race to publish, creating the release is
best-effort and the upload always clobbers.

Neither build carries certificates or secrets, so a fresh clone with zero
configuration still produces something. Sign the `.ipa` before installing.

⚠️ **The Android debug key is regenerated on every CI run**, because runners are
fresh VMs. Android refuses to update an app whose signing key changed, so each
update is an uninstall-and-reinstall that loses local data. Anything meant to be
used over time needs a real keystore supplied via secrets — and an
update-tracking app like Obtainium only works against a stable key.

## Known limitations

- **The API was never reached from this environment.** Egress policy blocks
  `a.4cdn.org`, so every model field, URL pattern and markup fixture comes from
  the published API documentation rather than from live responses. The parser
  fixtures are hand-constructed and marked as such. Anything that disagrees with
  real markup should be corrected against a real sample.
- **Compiling is not running.** CI proves the app builds and packages. It does
  not prove the app behaves correctly on a device.
- **WebM has no in-app player.** It is the only video container 4chan accepts
  and the one iOS will not play, so those open externally rather than in a
  player that cannot work.
- **WebM cannot be saved to Photos either.** The photo library stores what
  AVFoundation understands, which has never included WebM. Save reports that
  rather than failing quietly; sharing the file out is the way round it.
