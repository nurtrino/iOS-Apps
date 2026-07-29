# Dispatch

Four news apps in one, split by subject. Each topic is its own place with its
own furniture — no combined feed, no shared template. No account, no server in
between, no tracking: the app talks to the publishers directly from the device.

| Tab | What is on it |
| --- | --- |
| **War** | Live streams when something is on, the WarFront Witness wire in its own block, then The War Zone and anything else sorted here |
| **Politics** | Everything the classifier files as politics |
| **Markets** | BTC and S&P 500 with sparklines, the US release calendar, then the economics feed |
| **Gaming** | Steam news for your library across the top, then the wire — Wario64, Pirat Nation, CharlieIntel |
| **More** | Saved, Search, Sources, Streams, Steam, Settings |

## Sorting: how a story finds its section

Two of the sources only ever publish one thing — The War Zone is defense,
CharlieIntel is Call of Duty — so those are routed by declaration and can never
be misfiled. ZeroHedge and Citizen Free Press publish across all three of War,
Politics and Markets, and those are scored per story.

The scorer is a **weighted lexicon**, not a language model, and that is a
deliberate choice worth stating plainly. An on-device model big enough to beat a
tuned keyword list would add tens of megabytes and a second of latency per
refresh; a hosted one would mean shipping an API key and sending every headline
you read to a third party. The lexicon runs in microseconds, works offline, and
— the part that actually matters — is inspectable and testable, so a misfile is
a term to adjust rather than a shrug.

Three things make it better than a naive keyword match:

- **Phrases outrank words.** The words that belong to two topics at once are
  exactly the ones a naive matcher fumbles. "Strike" scores almost nothing
  alone; "air strike" and "authorize strike" score a lot, in opposite
  directions. Same for "bank" versus "central bank" versus "West Bank".
- **The headline outweighs the body**, 2.2 to 1. A markets piece that mentions
  Ukraine in its fourth paragraph is still a markets piece.
- **Distinct terms, not occurrences.** One repeated word in a long article
  cannot outvote five different signals in a short one.

Below a minimum score nothing is asserted — the story falls back to the
source's declared default and says so. Every article's reader shows the terms
that decided it ("Markets — yields, basis points"), which can be turned off in
Settings but is on by default: a heuristic nobody can question is just a black
box that is sometimes wrong.

The lexicon lives in `ios/Dispatch/Net/TopicLexicon.swift` and is **parsed
directly by the tests** rather than copied into them, so the table the tests
exercise is always the table the app ships.

## Rate mismatch, and why two sources get their own block

Merging by timestamp assumes everything arrives at a similar rate. Two sources
break that badly enough to need handling:

- **WarFront Witness** posts dozens of times an hour. Interleaved, it *is* the
  War feed, and every analysis piece ends up under a wall of one-line updates.
- **Steam** publishes a handful of patch notes a day, against three X accounts
  posting all day — so the news you opened the Gaming tab for was gone within
  an hour of a refresh.

Both are pulled out of their topic's main list into a fixed block at the top:
Steam as a horizontal rail of game cards, WarFront Witness as the newest five
with the rest one tap away. The main list underneath goes back to being
readable.

## Live streams

The War tab watches three YouTube channels and shows **only the ones that are
actually on**. An off-air card is a placeholder, and a row of placeholders
pushes the news down for nothing — when nothing is live the rail is not there
at all. What is on tonight lives in More › Streams, next to the switch that
controls it.

| Channel | Schedule |
| --- | --- |
| Mario Nawfal | Checked whenever the tab is open |
| Lookner | Checked whenever the tab is open |
| The Enforcer | Nightly except Monday, default 22:00 ET — editable |

Live status is checked for real, not guessed: the app loads the channel's
`/live` page and reads whether what it landed on is broadcasting. It fails
closed — anything ambiguous reports "not live", because a card that falsely
says LIVE is worse than one that misses a stream by a minute. A schedule only
decides *when to start checking*, so a show time being slightly wrong costs a
late card rather than a wrong one.

Streams play in-app through the official YouTube embed in a `WKWebView`. That is
not a shortcut — it is the only legitimate option, since YouTube's media URLs
are signed, short-lived and explicitly not for third-party players.

The embed goes in an `<iframe>` inside a minimal local page whose `baseURL` is
youtube.com, **not** in the web view's address bar. Navigating straight to
`youtube.com/embed/<id>` is the obvious approach and it does not work: that
endpoint expects to be framed, and as a top-level document it answers "Video
unavailable — watch on YouTube" often enough to be useless, live streams
especially.

**X livestreams cannot be detected.** There is no unauthenticated way to ask
whether an X account is live, so the Mario Nawfal X card (off by default) always
opens X rather than claiming to know.

## Markets data

| What | Source | Fallback |
| --- | --- | --- |
| Bitcoin | Coinbase public candles, 15-minute buckets | — |
| S&P 500 | Yahoo Finance chart endpoint, 5-minute buckets | Stooq daily CSV |

Both are public and need no key, and neither promises to stay that way — so the
card names whichever provider answered.

The **economic calendar is generated on device**. There is no free calendar API
worth depending on, but most of what matters is a rule rather than a feed:
jobless claims every Thursday at 8:30, payrolls the first Friday, ISM on the
first business day. Those are exact. The releases that genuinely drift — CPI,
PPI, retail sales, PCE — are marked with a `~` and shown as approximate,
because a calendar that renders a guess and a published date identically is
worse than no calendar. FOMC dates come from the Fed's published schedule,
shipped as a table; `precheck.py` fails once that table is close to running out
so it cannot quietly go stale.

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

Set one up in **More › Settings › X bridge**, then tap **Test the bridge** —
it resolves the template against a real handle, fetches it, and reports the item
count or the exact failure. The "Resolves to" line shows the precise URL it will
request.

Public instances get rate limited into uselessness quickly, so a self-hosted one
is the arrangement that keeps working. RSSHub in Docker is the usual answer:

```sh
docker run -d --name rsshub -p 1200:1200 \
  -e TWITTER_AUTH_TOKEN=<the auth_token cookie from a logged-in X session> \
  diygod/rsshub
```

Then set the kind to RSSHub and the instance to `192.168.x.x:1200`. A host on
your own network defaults to `http` and is permitted to use it —
`NSAllowsLocalNetworking` in the Info.plist relaxes App Transport Security for
private addresses only, leaving it fully in force for the public internet.
Anything else defaults to `https`.

Both X routes need a logged-in session token, because X blocks the anonymous
paths these bridges originally used. Use a throwaway account: an automated
reader on a token is the sort of thing X suspends accounts over.

If a service mints one opaque feed URL per account rather than a templated one,
it cannot be a bridge — there is no `{handle}` to substitute. Paste those URLs
into each X source's **Backup feeds** list instead, in More › Sources.

**With no bridge configured the app still works.** Each X source falls back to a
real RSS feed and says so with a one-line note under the section header:

| X source | Falls back to |
| --- | --- |
| ZeroHedge Wire (`@zerohedge`) | ZeroHedge's own full feed |
| Wario64 | PC Gamer, then Rock Paper Shotgun |
| Pirat Nation (`@Pirat_Nation`) | Eurogamer |
| CharlieIntel (`@charlieINTEL`) | charlieintel.com |
| Genki (`@Genki_JPN`, off by default) | Gematsu |

For ZeroHedge that is the same newsroom — the site feed rather than the
timeline — so the Wire section is genuinely useful out of the box.

## Steam setup

Two routes, and the manual one needs no credentials at all.

**By API key.** More › Steam, paste a key from
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
  Model/      Article, Source, Topic, LiveChannel, LoadPhase
  Net/        HTTP, feed parsing, HTML handling, the classifier and its
              lexicon, YouTube live checks, market endpoints
  Data/       stores — catalog, feeds, live, markets, calendar, read state,
              settings, Steam library
  UI/         SwiftUI screens, one per topic plus shared furniture
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
- Topic sorting, against the shipped lexicon: the clear cases, and every
  ambiguous word that a naive matcher gets backwards — air strike versus strike
  authorization, West Bank versus central bank, campaign rally versus market
  rally, tariffs on a political outlet.
- Classifier normalisation. Two bugs came out of writing those: `Powell's`
  normalised to `powells` and matched nothing, and a headline spelling it
  `air-strike` never matched the phrase `air strike`.

The fixtures are hand-constructed — this build environment's egress policy
blocks every one of these hosts, so nothing was captured live. Anything that
turns out to disagree with a real payload should be corrected against a real
sample and the Swift updated in step.

`precheck.py` also catches, without a compiler: unbalanced brackets, trailing
commas before `)` (legal in Swift 6.1, not in Swift 5), API that postdates the
iOS 16 deployment target, a source file missing from the Xcode project, a
background-task identifier that does not match Info.plist, duplicate catalog
ids, a lexicon line the test parser would silently skip, and an FOMC table
running out.

## Build

```sh
python3 dispatch/tools/precheck.py            # static checks + parser tests
python3 dispatch/tools/gen_pbxproj.py         # regenerate after adding a file
python3 dispatch/tools/make_icons.py          # regenerate the icon

xcodebuild build -project dispatch/ios/Dispatch.xcodeproj -scheme Dispatch
```

One build setting is load-bearing and non-obvious: `PRODUCT_MODULE_NAME` is
`DispatchNews`, not `Dispatch`. `Dispatch` is Apple's own module — libdispatch,
where `DispatchQueue` lives — and Foundation imports it, so a target whose Swift
module is also called `Dispatch` produces `circular dependency between modules
'Dispatch' and 'Foundation'` and never compiles. Nothing refers to the module by
name, so the product, the scheme, the `.app` and the name on the home screen all
stay "Dispatch".

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
- **A link aggregator opens the web page**, not the reader. Citizen Free Press
  ships with this on: its feed items are pointers to somebody else's article
  with an empty description, so the reader had nothing to render and showed a
  stub with a button on it. Any source can be switched either way in
  More › Sources.
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
