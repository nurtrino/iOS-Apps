# Dispatch

Four news apps in one, split by subject. Each topic is its own place with its
own furniture — no combined feed, no shared template. No account, no server in
between, no tracking: the app talks to the publishers directly from the device.

| Tab | What is on it |
| --- | --- |
| **War** | A one-tap link to live coverage in the YouTube app, the brief, then The War Zone, the Middle East Spectator Telegram wire and anything else sorted here |
| **Politics** | Citizen Free Press and the rest, newest first |
| **Markets** | BTC and S&P 500 with sparklines, the US release calendar, then the economics feed |
| **Tech** | Space news across the top — Payload, Spaceflight Now — then the wire: The Register, Pirate Wires, Cryptogon |
| **More** | Gaming, Saved, Search, Sources, Streams, Steam, Settings |

Five tabs, and iOS shows only five. War, Politics, Markets and Tech are the
all-day sections and take the visible slots; **Gaming moved into More**, opened
full-screen from there, since it is read least like a wire — patch notes for the
games you played, not something happening now. Everything it had is intact.

Two things that changed shape: War no longer plays streams in a rail — the embed
was refused too often — and instead links straight into the YouTube app, jumping
to a stream that is live now or a war channel's live tab when none is. And
**Citizen Free Press is a plain political source** rather than a classified one:
it was being scored per story and split across three sections, which is correct
filing and was also why "where did CFP go" kept coming up. It is a political
aggregator, so all of it lands in Politics, newest first.

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

Below a minimum score nothing is asserted, and the story takes the source's
declared default — **always**. A lexicon that hides what it has no words for
turns every missing term into a missing story, which is exactly what happened
when it was allowed to: a wire posting a hundred headlines a day uses words
outside a five-hundred-term table all day long, and a third of Citizen Free Press
went invisible. Deciding a story fits nowhere is a judgement, and the lexicon is
not equipped to make it.

### Claude does the filing

With an Anthropic key saved and sorting on (Settings › Claude), stories from a
general outlet are filed by `claude-haiku-4-5` instead. Forty headlines go in one
request; each answer is stored against the article id forever and never asked
again, so the steady state is one or two requests a day and most refreshes send
nothing. Only headline text goes over the wire.

The model may also answer **none** — the story belongs in no section. That is the
only thing that ever hides a story, and only where the source is set to
"Skip stories that fit nowhere" (on for CFP, off for ZeroHedge, whose default is a
fair guess). Hidden stories are not deleted: they are on the source's own screen
and in Search, and the reader says so instead of pretending.

Everything degrades to the lexicon. No key, no network, a rate limit, a refusal —
the term list files the story and nothing is lost. The reader's evidence line says
which decided: terms, a default, or "filed by Claude".

The threshold is tested against the **evidence alone**, before the source prior is
added. The prior is a belief about the source, not something the story said, and
letting it push a total over the line meant one weak word plus "this outlet is
usually politics" counted as having seen something — which is how "University
wins college football championship" became a politics story. The prior now only
breaks ties between topics that both cleared on their own.

Every article's reader shows the terms that decided it ("Markets — yields, basis
points"), or says "No section" where nothing matched. That can be turned off in
Settings but is on by default: a heuristic nobody can question is just a black
box that is sometimes wrong.

The lexicon lives in `ios/Dispatch/Net/TopicLexicon.swift` and is **parsed
directly by the tests** rather than copied into them, so the table the tests
exercise is always the table the app ships.

### Is it actually working?

Unit tests on the ambiguous words are not the same question as "does this work on
what these outlets really publish", so there are two **corpora** in
`test_feeds.py`, scored exactly as the app scores them:

- **ZeroHedge, 33 headlines** with bodies, since it syndicates full text.
- **The aggregator, 73 headlines**, title-only and bodyless because that is what
  a link post is — including ten that are genuinely none of the three topics and
  must be *dropped* rather than filed.

The first corpus started at 30 of 33. All three failures were the same thing: **no
lexicon term matched at all**, so the story took the source's default. A carrier
redeployment filed itself under Markets; "Massive explosion reported in Riyadh"
filed itself under Politics.

The aggregator corpus then found the same failure at scale: **24 of 73** matched
nothing and were being filed under Politics — a section that looked like news and
was a third guesswork. That is the failure mode you cannot see from inside the
app, so both corpora also assert that **nothing reaches its section by fallback**.

That corpus is also the cautionary tale in this repository. It passed 73 of 73,
and then real headlines arrived and stories went missing anyway — because the 73
were written by the same hand that wrote the lexicon, so all they proved was that
the table covered its author's idea of that wire. It is a regression test, not
evidence about the world. What it did earn is the *shape* of the fix: the lexicon
never hides anything, and the judgement call moved to a model that has read more
headlines than anyone is going to enumerate by hand.

Roughly 200 terms went in to close it, and every one of them arrived with a second
meaning attached. Those are pinned too, each from a real misfile found by probing:
a university winning a championship, a professor finding a beetle, a film that
bombs at the box office, a hike on the Appalachian Trail, a price war among
airlines, a union striking a deal, an explosion in demand for used cars, and
winning gold at the Olympics. "Blast" is deliberately absent from the lexicon
entirely: on these outlets it is how "criticises" is spelled.

Two mechanisms came out of that. Weights **below** the threshold for terms that
need company ("strikes", "bombs", "explosion", "university" — each decisive only
when paired with somewhere or something). And **negative weights**, where a phrase
cancels the term it contains: `("olympics", -3.0)` in the economics table is what
keeps "wins gold at the Olympics" out of Markets without giving up "gold" as a
commodity. Same shape for "price war" and "war of words".

`precheck.py` checks the wiring underneath, too — every source declares a
`fixedTopic` (which doubles as its fallback), every classified source declares a
prior, and nothing is in `defaults` and `retired` at once.

## Rate mismatch

Merging by timestamp assumes everything arrives at a similar rate, and **Steam**
breaks that: a handful of patch notes a day against a gaming wire posting all
day, so the news you opened the Gaming tab for was gone within an hour of a
refresh. It gets a horizontal rail of game cards above the list rather than a
place in it.

Space has the same shape on the **Tech** tab: Payload and Spaceflight Now are
pulled out of the main tech wire into their own rail across the top, with an
"All" door to every space story merged, so launch news is not interleaved with
chip news and platform politics. (Next Spaceflight was asked for by name but
publishes no feed of any kind — a client-rendered app, no RSS — so Spaceflight
Now stands in for it on the same beat.)

One Telegram channel ships as a default again: **the Middle East Spectator**, on
War. War channels open nearly every post with a wall of flags and sirens, and
since a Telegram post has no title the headline is derived from the first run of
its text — so the emoji land exactly where the headline should be. They are
stripped from the derived text, narrowly: pictographs, flags, skin-tone
modifiers and joiners go, while the digits in "5 killed" stay. (An earlier
frontline channel was retired for volume it could not be tamed out of; Telegram
remains a source **kind**, so any channel can still be added by hand.)

**A post whose destination is a video plays the video.** A link wire's post is
often a YouTube link with a sentence attached; the page around it is a consent
wall and comments. So when the resolved destination is a YouTube link, the tap
hands off to the **YouTube app** — the real player and your account — falling
back to an in-app sheet when the app is not installed. A direct file (a Telegram
clip) always plays in the sheet.

**Video and live streams never fall back to Safari.** This took getting the
diagnosis right. YouTube's embed error 150/153 is usually read as "the owner
disabled embedding", but on iOS it is far more often *"embedder identity missing
referrer"* — WKWebView does not send a `Referer` for a cross-origin iframe, so
YouTube cannot verify the embedder and refuses. The player now sends what
YouTube needs: a `<meta name="referrer">` policy, an `origin` player var, and a
real mobile-Safari user agent, which is most of the fix. When a video is
*genuinely* embedding-disabled or age-restricted, the fallback is not a browser —
the same `WKWebView` loads YouTube's own watch page (`m.youtube.com/watch`),
which is the real site rather than an embed, so the restriction does not apply
and it plays. Nothing here ever opens Safari. (The one exception is a live *X*
stream, which has no embeddable player of any kind.)

A third rate problem is invisible rather than ugly. **A feed is a window, not an
archive**: Citizen Free Press publishes dozens of items a day and its RSS holds a
fraction of them, so a refresh that replaced a source's list lost every story
that entered and left that window between two fetches — and dropped anything
already read the moment it scrolled off the feed. `FeedStore.merge` folds each
fetch into what is already held instead, newest first, incoming copy winning an
id collision (that is where a corrected title or a resolved outbound link
arrives), capped at 120 items per source. The app accumulates the history the
feed does not keep. The cost is that a post deleted upstream lingers until it
ages out, which is the right way round.

Freshness has three triggers, all of them staleness-gated so none of them
thrashes: launch, switching to a tab, and returning to the app. The last one caps
staleness at two minutes regardless of the Refresh setting — that setting exists
to stop a background poll from running constantly, not to make a reopened app
show hour-old news. Pull-to-refresh and the toolbar button always force.

Those blocks push through a `NavigationPath` rather than containing
`NavigationLink`s. SwiftUI treats a List row as a single destination, so several
links crammed into one row fight over the back button — which is exactly what
went wrong the first time. One row per post, one tap target each, and rails
report the tap to the screen that owns the path.

Telegram video posts play in place. Telegram serves them as a plain MP4 on its
CDN with no signing, so a video post opens an `AVPlayer` rather than a web page
— for a video post the video *is* the post, and opening the caption was throwing
the content away.

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

Tapping a live card plays the stream in the app, through YouTube's official
embed in a `WKWebView`.

The embed has one failure no client can avoid: **a channel can switch embedding
off**, and YouTube enforces that server-side with "Playback on other websites
has been disabled by the video owner". Channels living on ad revenue often do.
So the player uses the IFrame Player API rather than a bare iframe, purely to
hear the `onError` callback — codes 101 and 150 both mean "not embeddable" — and
turns that into an offer of Safari instead of a black rectangle. A watchdog
covers the case where the API script never loads at all.

The good case stays in the app; the bad case is one tap and honest about why.

**X livestreams cannot be detected.** There is no unauthenticated way to ask
whether an X account is live, so the Mario Nawfal X card (off by default) always
opens X rather than claiming to know.

## The brief

Each topic opens with a catch-up block, and it contains **no headlines**. It used
to open with five of them, numbered, and they were the same stories as the list
directly underneath — the same words twice on one screen, and a wire having a busy
hour could fill all five slots with one thread. The list below is the list. The
brief says what happened; scrolling says what else.

**The whole block exists only when there is an Anthropic key.** Without one there
is no brief anywhere in the app — not an empty header, not a state line on its
own. The written summary is the section's reason to exist; the numbers beside it
are context for that, and Markets already has the prices in a chart directly
above. A header with nothing under it is furniture.

With a key, it is two things: the bullets, and a **state line** of real fact where
the topic has one — on Markets the actual index moves and whether a release has
already landed today, which is the question that section gets asked at nine in the
morning.

**AI summaries.** Paste an Anthropic API key in Settings → AI summaries and the
brief opens with a few bullets written by Claude (`claude-haiku-4-5`, over raw
HTTPS to `v1/messages` — there is no Swift SDK) saying what just happened. Haiku
rather than an Opus deliberately: the job is four lines off headlines that are
already written, and it runs across four sections all day.

The summary reads the newest eight items in the window, capped at three per source
so one busy source cannot fill the prompt. What is sent is only ever headline
text, source names and ages. No article bodies, no reading history.

A summary regenerates only when that pool actually changes *and* the last one is
at least five minutes old. The input is hashed (`SummaryStore.inputKey`) so a
refresh that reorders the same headlines does not bill; the model id and a prompt
revision are part of the same hash, so changing either invalidates every stored
brief rather than leaving the old model's prose in place. While the first one is
being written the block shows only that it is being written — a half-drawn brief
that rearranges itself under your thumb is worse than a second of waiting.

The key lives in the Keychain, `ThisDeviceOnly`, same as the Steam key; a failed
or keyless request degrades to the plain digest, never to an error screen.

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

**Tapping a release shows the numbers.** A calendar answers "when", which is only
half of what that section is opened for, so each entry opens a sheet with the last
published figures for the series it covers — CPI and core CPI year over year, the
monthly change in payrolls plus the unemployment rate, initial claims against the
previous week, the fed funds target — over a table of the last eight periods.

They come from **FRED** via `fredgraph.csv`, which needs no key; FRED's documented
API requires one, and this app's rule is that a feature cannot depend on the
reader signing up for anything. The trade is that it is a convenience endpoint
rather than a contract, so the sheet is allowed to fail and says so when it does.
Its CSV is also quietly hostile — the first column header has been both `DATE` and
`observation_date`, a missing observation is a bare `.`, and the line endings are
CRLF — so the parser skips the header by *shape* rather than by name, and every one
of those cases is a test.

Two honesty rules apply. The numbers are for the period **already published**,
which for a monthly release is the previous month, so the sheet labels the period
rather than implying the figure belongs to the date above it. And **ISM has no free
series**: FRED's were pulled for licensing reasons, so those two entries say that
outright instead of showing an empty table.

## How each source is read

Four transports, because these sources have nothing in common technically.

**RSS** — ZeroHedge, Citizen Free Press, The War Zone. RSS 2.0, Atom and
RSS 1.0/RDF all go through one parser. Every source carries backup feed
addresses that are tried in order when the primary is unreachable, which is
what keeps a section from emptying because one host is having a bad day.

**Telegram** — no channel ships as a default any more (see *Rate mismatch*), but
the transport is still there for one added by hand. Telegram publishes no RSS, and
its Bot API cannot read a channel the bot was not added to as an admin. What a
public channel does have is `t.me/s/<channel>`, a server-rendered page of recent
posts requiring no account. That page is parsed directly. It is scraping, so it
degrades rather than fails: a post with no text still yields its photo and its
link, and a video post — which Telegram serves as a plain MP4 on its CDN — plays
in the reader.

**Steam** — `ISteamNews/GetNewsForApp` needs no API key, so game news works with
nothing configured beyond a list of App IDs. Discovering that list automatically
needs a Web API key and a public profile; see below.

Two things about Steam announcements need handling. Their bodies are BBCode with
`{STEAM_CLAN_IMAGE}` placeholders that Steam substitutes when *it* renders the
page — through the API they arrive raw, so every image is a broken link with a
curly-braced path beside it. And the API has no language parameter and no
language field, so a studio posting in Chinese lands in the same list as one
posting in English. Placeholders are expanded, unmodelled tags are stripped
(narrowly — patch notes are full of bracketed prose like `[PC]` and `[Fixed]`,
which stays), and a script check drops announcements whose title is mostly
non-Latin. That check separates alphabets, not languages: telling Spanish from
English needs a model, telling Cyrillic from Latin needs a Unicode range.

**X** — see the next section, because it is the one that comes with a caveat.

## X: nothing ships as an X source

X has no free public read API. Reading a timeline requires either a paid API
tier or a server that reads on your behalf and republishes as RSS, and that
server needs a logged-in session cookie from a real account. There is no third
option and no client-side workaround.

Rather than ship sources that need all that before they work, the gaming
accounts were replaced with the newsrooms' own feeds — **CharlieIntel** is
literally the same newsroom as the X account, and Gematsu, VGC and PC Gamer
cover the same beat. Those need no bridge, no token and no setup.

The X support is still there for an account you add yourself in More › Sources.
It supports the bridges people actually run:

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
  -e TWITTER_AUTH_TOKEN=<auth_token cookie> \
  diygod/rsshub
```

Then set the kind to RSSHub and the instance to `192.168.x.x:1200`. A host on
your own network defaults to `http` and is permitted to use it —
`NSAllowsLocalNetworking` in the Info.plist relaxes App Transport Security for
private addresses only, leaving it fully in force for the public internet.
Anything else defaults to `https`.

### Getting the auth_token

X blocks the anonymous paths these bridges originally used, so the route needs a
logged-in session cookie. It is a browser cookie, not an API key — there is no
developer portal involved.

1. **Make a throwaway X account.** Do not use your own. An automated reader
   running on a session token is the sort of thing X suspends accounts over,
   and the token is a full session — anyone holding it is logged in as that
   account.
2. Log into `x.com` with it in a desktop browser.
3. Open developer tools — **Application → Cookies → https://x.com** in
   Chrome or Edge, **Storage → Cookies** in Firefox.
4. Find the row named **`auth_token`** and copy its Value: about 40 hex
   characters. That is the whole thing.
5. **Close the tab. Do not log out.** Logging out invalidates the token
   server-side and you would have to start over.

Verify the bridge before touching the app:

```sh
curl -s localhost:1200/twitter/user/Wario64 | head -20
```

Items back means it works; an error or empty feed means the token was rejected.

The variable takes a comma-separated list, so several throwaway accounts can
share the rate limit:

```sh
-e TWITTER_AUTH_TOKEN=token1,token2
```

Tokens die on logout, on a password change, and on their own after a while, so
expect to redo this occasionally. When one expires the X sources fall back to
their backup RSS feeds and say so, rather than going silent.

RSSHub's own configuration is the authority here and has changed before —
check [its Twitter route docs](https://docs.rsshub.app/routes/social-media#twitter)
if the variable name has moved on.

If a service mints one opaque feed URL per account rather than a templated one,
it cannot be a bridge — there is no `{handle}` to substitute. Paste those URLs
into each X source's **Backup feeds** list instead, in More › Sources.

**With no bridge configured an X source still works**, falling back to whatever
backup feeds it carries and saying so in a line under the header — and rows
served that way are badged with the host that actually answered rather than the
handle that did not write them.

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
- The Claude request. The wire constants are read *out of* `SummaryAPI.swift`, so
  a typo'd endpoint or version header fails a test rather than a live request,
  and the prompt is pinned byte for byte.
- The summary cache key, against published FNV-1a vectors — it decides when money
  is spent, so "the same headlines in a different order" has to hash the same and
  "a different model" has to hash differently.
- Bullet parsing, including the case that makes a naive marker-stripper wrong: a
  line opening `3.4% and rising` must not lose its `3.` to the list-marker rule.
- The feed merge: retention, newest-first ordering, and the incoming copy winning
  an id collision.

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

## The icon

`design/icon-source.png` is the artwork; `tools/make_icons.py` turns it into the
icon Xcode ships. There are no image libraries in this environment, so that file
contains a PNG decoder as well as an encoder.

Three things happen to a supplied export, and each one is there because of a
visible failure:

- **It is cropped to its content and made full-bleed in the artwork's own
  background colour.** iOS applies its own superellipse mask, so an image that
  rounds its own corners and sits on white keeps that white *outside* its curve
  and inside Apple's — four pale wedges around a dark square.
- **Everything that is not the mark is flattened**, in two passes. A flood fill
  inward from the border removes the page and the soft ring where the artwork's
  curve meets it; that ring is lighter than anything in the mark, so left behind
  it won the "what is the brightest colour here" question and became the app's
  tint, sampled from an anti-aliasing artifact. Then a floor — nothing darker than
  the ground — catches the drop shadow, which a fill cannot reach because a shadow
  fades *through* the ground value on its way out and the fill stops at that ring.
- **The mark is lifted away from its background.** A dark grey mark on near-black
  is handsome at full size and a black square at 60 points. The lift scales each
  pixel's distance from the ground, so the ground stays exactly flat — which
  matters, because Apple's mask cuts into it — with a deadzone so the export's
  grain is flattened rather than multiplied.

The tool prints the ground and the artwork's lightest colour every run, and says
when that colour is too dark to tint an interface with — which is the case here,
so `Palette.accent` is neutral and the four section colours are the only colour in
the app. `precheck.py` checks the result is 1024², 8-bit and **RGB with no alpha**,
because iOS rejects an alpha channel and nothing says so until you try to ship.

Delete the source file and the tool goes back to generating its own mark.

## Android

The same app, ported, in `android/`. Two modules split by where each can be
verified:

- **`core`** is pure Kotlin with no Android dependency at all: XML repair, the
  feed parser, HTML to text, the article and source models, the classifier, and
  the Claude request and reply handling. It compiles and its tests run on any
  JVM, which means they run during development rather than only on CI. 70 tests,
  ported from `tools/test_feeds.py`.
- **`app`** is Compose, and everything that touches an Android API. It needs the
  SDK, so `settings.gradle.kts` includes it only when `ANDROID_HOME` is set —
  without that guard a checkout with no SDK cannot even *configure* the build,
  because Gradle resolves the Android plugin before it runs anything, and
  `core`'s tests fail for reasons that have nothing to do with the code.

The lexicon is **generated from the iOS Swift** by `tools/gen_lexicon_kt.py`.
Five hundred weighted terms maintained in two languages would diverge inside a
week, and the divergence would be invisible — both apps would keep working and
quietly file the same story differently. CI runs the generator with `--check` and
fails if the Kotlin is stale. That makes three consumers of one table: Swift, the
Python tests, and Kotlin.

The behaviours that were learned the hard way came across with it: merge rather
than replace so a fast wire does not lose stories, the browser user agent that
stops Cloudflare returning 403, ids derived before any link rewriting, outbound
link resolution for aggregators, and model decisions cached per article id.

`.github/workflows/dispatch-android.yml` builds a **debug APK** and publishes it
to the rolling `latest` release as `Dispatch-debug.apk`, next to the iOS `.ipa`.
It is also a workflow artifact, but that needs a GitHub login and an unzip; a
release asset is a bare URL a phone's browser can install from, which for Android
is the whole delivery mechanism. Debug because the standard debug key is the only
key that exists in a public repository: it installs from a file manager with
"unknown sources" allowed, and it is not a Play Store artifact.

The workflow watches all of `dispatch/`, not just `dispatch/android/`. Scoped to
the Android directory it stopped rebuilding while the shared lexicon and source
catalog moved underneath it, so the published APK carried a fortnight-old
classifier. `versionCode`/`versionName` come from the run number via
`-PdispatchBuild=`, the build asserts with `aapt2 dump badging` that the stamp
took, and the top bar shows `BuildConfig.VERSION_NAME` — the same three-part
answer to "which build is on the phone" that the iOS side needed.

**Not ported yet:** the brief, the live rail, Steam, the release calendar,
per-source screens and settings. The Android app reads and files; the furniture
is iOS-only so far.

The root build's `buildscript` block puts the Android plugin on the classpath only
when there is an SDK, and every module applies plugins by id with no versions.
That is deliberate and cost four CI runs to arrive at: declaring the Android
plugin in a root `plugins { }` block breaks any machine without access to Google's
Maven repository, and declaring only the Kotlin plugins there loads them in a
different classloader from AGP — after which the Kotlin Android plugin cannot see
AGP's classes and fails on a missing `BaseVariant`. One shared buildscript
classpath avoids both.

## Build

```sh
python3 dispatch/tools/precheck.py            # static checks + parser tests
python3 dispatch/tools/gen_lexicon_kt.py      # regenerate the Android lexicon
cd dispatch/android && ./gradlew :core:test   # the Kotlin port's tests
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
- **A link aggregator opens the linked article**, not the reader and not its own
  permalink. Citizen Free Press ships with both flags on: its items are pointers,
  and its permalink is a stub page — a headline with a "Go To Article" link under
  it — so stopping there is a dead end with an extra tap. The outbound anchor is
  taken from the feed where it is present and fetched from the permalink on tap
  where it is not, cached either way. Both flags are switchable per source in
  More › Sources.
- **A source served from a backup feed says whose article it is.** Without an X
  bridge, Wario64's row is filled by PC Gamer, and badging that "WARIO64" is
  simply false — the row carries the host that actually answered.
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
