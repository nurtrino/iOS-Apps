# Dispatch

A news reader for a specific set of sources, split into sections you swipe
between. No account, no server in between, no tracking — the app talks to the
publishers directly from the device.

| Section | Sources |
| --- | --- |
| **Top** | Everything below, merged and sorted newest first |
| **Wire** | ZeroHedge, as quick headlines |
| **Markets** | ZeroHedge, full articles |
| **Front Page** | Citizen Free Press |
| **Defense** | The War Zone, WarFront Witness (Telegram) |
| **Gaming** | Steam news for your library, gaming X accounts |

Sections and sources are both editable — rename them, reorder them, add your
own, move a source from one section to another. The list above is the default,
not a fixture.

## How each source is read

Four transports, because these sources have nothing in common technically.

**RSS** — ZeroHedge, Citizen Free Press, The War Zone. RSS 2.0, Atom and
RSS 1.0/RDF all go through one parser. Every source carries backup feed
addresses that are tried in order when the primary is unreachable, which is
what keeps a section from emptying because one host is having a bad day.

**Telegram** — WarFront Witness (`@wfwitness`). Telegram publishes no RSS, and
its Bot API cannot read a channel the bot was not added to as an admin. What a
public channel does have is `t.me/s/<channel>`, a server-rendered page of recent
posts requiring no account. That page is parsed directly. It is scraping, so it
degrades rather than fails: a post with no text still yields its photo and its
link.

**Steam** — `ISteamNews/GetNewsForApp` needs no API key, so game news works with
nothing configured beyond a list of App IDs. Discovering that list automatically
needs a Web API key and a public profile; see below.

**X** — see the next section, because it is the one that comes with a caveat.

## X needs a bridge, and that is not fixable in the app

X has no free public read API. Reading a timeline requires either a paid API
tier or a server that reads on your behalf and republishes as RSS. There is no
third option and no client-side workaround.

So Dispatch supports the bridges people actually run:

- **Nitter** — reads `<host>/<handle>/rss`
- **RSSHub** — reads `<host>/twitter/user/<handle>`
- **Custom** — any URL containing `{handle}` that returns RSS or Atom

Set one up in **Settings › X bridge**. Public instances get rate limited into
uselessness quickly, so a self-hosted instance is the arrangement that keeps
working.

**With no bridge configured the app still works.** Each X source falls back to a
real RSS feed and says so with a one-line note under the section header:

| X source | Falls back to |
| --- | --- |
| ZeroHedge Wire (`@zerohedge`) | ZeroHedge's own full feed |
| Gaming Wire (`@Wario64`) | PC Gamer, then Rock Paper Shotgun |
| Genki (`@Genki_JPN`, off by default) | Gematsu |

For ZeroHedge that is the same newsroom — the site feed rather than the
timeline — so the Wire section is genuinely useful out of the box.

## Steam setup

Two routes, and the manual one needs no credentials at all.

**By API key.** Settings › Steam, paste a key from
[steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey), enter
your Steam ID or profile name, and sync. The key is stored in the iOS Keychain
(`ThisDeviceOnly`, so it does not travel in a backup) and is sent only to Valve.
It is used once, to list what you own.

This needs **Game details** set to Public in your Steam privacy settings. If
Steam returns an empty list, that is almost always why, and the app says so
rather than showing "no games".

**By App ID.** Add games by the number in their store URL —
`store.steampowered.com/app/730/` is App ID 730. News itself needs no key, so
this route works entirely without credentials.

Either way, games are followed most-recently-played first, and each one is a
separate request — so following forty of them makes the Gaming section
noticeably slower to refresh. Tap a game to stop following it without removing
it.

## Layout

```
ios/Dispatch/
  Model/      Article, Source, FeedSection, LoadPhase
  Net/        HTTP, feed parsing, HTML handling, per-source loaders
  Data/       stores — catalog, feeds, read state, settings, Steam library
  UI/         SwiftUI screens
  Media/      image loading
tools/
  gen_pbxproj.py     writes the Xcode project from what is on disk
  make_icons.py      draws the app icon
  feed_reference.py  Python mirror of the parsing logic
  test_feeds.py      assertions against that mirror
  precheck.py        everything above, plus static checks
```

### The parsing layer, and why it is mirrored in Python

Most of this app is a parser, and a parser bug in a feed reader does not crash —
it shows an empty section, and nobody notices for a week. There is also no Swift
compiler in the environment this was written in, so every real compile is a CI
round trip of several minutes.

So the pure string-to-data logic is mirrored function-for-function in
`feed_reference.py` and tested in `test_feeds.py` — 107 assertions covering the
cases that actually break feed readers:

- HTML entities inside XML. `&nbsp;`, `&mdash;` and `&rsquo;` are undefined in
  XML, and `XMLParser` is non-recovering: one of them aborts the parse and the
  source returns nothing. Nearly every RSS feed contains them. They are rewritten
  to numeric references before parsing, along with bare ampersands ("Q&A"),
  control characters, and an `encoding=` declaration that no longer describes
  the bytes.
- `src` versus `data-src`. Most WordPress themes put a grey placeholder in `src`
  and the real photo in `data-src`, so reading `src` alone gets a blank image in
  every row.
- `<sect` versus `<section`. Removing `<script>` blocks by prefix match deletes
  the entire body of any site that wraps content in `<section>`.
- Telegram's reply previews, which use a class name one token away from the
  post's own, and its spoiler divs, which truncate any post that contains one if
  `</div>` matching is not balanced.
- Source newlines. They are insignificant whitespace in HTML; treating them as
  line breaks puts one in the middle of every sentence of an eighty-column feed.
- Dates in the eight formats feeds actually use. An unparsed date sorts to the
  bottom of a merged feed, so a source with an unhandled format looks like it
  stopped updating.

The fixtures are hand-constructed — this build environment's egress policy
blocks every one of these hosts, so nothing was captured live. Anything that
turns out to disagree with a real payload should be corrected against a real
sample and the Swift updated in step.

`precheck.py` also catches, without a compiler: unbalanced brackets, trailing
commas before `)` (legal in Swift 6.1, not in Swift 5), API that postdates the
iOS 16 deployment target, a source file missing from the Xcode project, a
background-task identifier that does not match Info.plist, and duplicate catalog
ids.

## Build

```sh
python3 dispatch/tools/precheck.py            # static checks + parser tests
python3 dispatch/tools/gen_pbxproj.py         # regenerate after adding a file
python3 dispatch/tools/make_icons.py          # regenerate the icon

xcodebuild build -project dispatch/ios/Dispatch.xcodeproj -scheme Dispatch
```

The Xcode project is generated rather than hand-maintained: a source file that
exists on disk and is not listed in the project simply is not compiled, and the
failure surfaces much later as an undefined symbol pointing at the use rather
than the omission. `gen_pbxproj.py --check` asserts the committed project still
matches the tree, and CI runs it.

CI builds an unsigned `.ipa` on every push and uploads it to the repository's
rolling `latest` release. It is unsigned deliberately, so a fresh clone with no
certificates and no secrets still produces an artifact — sign it before
installing.

## Notes and limits

- **iOS 16 and later.** Deployment target 16.0, no third-party dependencies.
- **Search is local.** It filters the stories already on the device and says how
  many that is. None of these sources offers a search API worth using.
- **Read state is capped** at 8,000 articles, oldest dropped first. Unbounded, it
  only ever grows.
- **Saved articles keep their own copy** of the text. Feeds roll off after twenty
  or forty items, so a saved article that was only a pointer would be a dead row
  within a day.
- **Background refresh is a request, not a promise.** iOS decides whether and
  when it runs, based on how the app is actually used.
- **The request User-Agent is a browser string.** `URLSession`'s default gets a
  403 from a meaningful share of these hosts — Cloudflare in front of WordPress,
  mostly — and several built-in sources are unreachable without it.
