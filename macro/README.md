# Macro

An economics news desk in four tabs: a merged wire of hand-picked econ/markets
sources, the Forex Factory economic calendar, a chartable market watchlist, and
the settings that make the notifications yours.

## What it does

**News.** One merged feed from ten sources — ZeroHedge, CNBC Economy,
MarketWatch, BBC Business, FXStreet, Investing.com, Calculated Risk,
Wolf Street, Naked Capitalism, The Economist's finance section. Every source
can be toggled off, every source carries fallback addresses so a host having a
day degrades to a "quiet" advisory rather than an empty screen. Stories open in
an in-app Safari sheet; swipe to save, filter by source, search headlines.

**Calendar.** Forex Factory's economic calendar — this week and next, every
currency, impact-coded, with forecast and previous values. FF publishes the
JSON its own calendar widget runs on from a CDN
(`nfs.faireconomy.media/ff_calendar_thisweek.json`), no key needed. Filter by
impact floor and by currency chips.

**Markets.** A dozen instruments — S&P 500, Nasdaq 100, Dow, EUR/USD, GBP/USD,
USD/JPY, AUD/USD, gold, silver, WTI, Bitcoin, the US 10-year yield — each with
last price, day change and a month sparkline, opening into a full Swift Charts
view with 1M/3M/6M/1Y ranges and drag-to-scrub. Daily history comes from
Stooq's keyless CSV endpoint; FX pairs fall back to Frankfurter (ECB reference
rates) when Stooq doesn't answer.

**Notifications.** Two kinds, both generated on-device:

- *Event reminders* — high (or high+medium) impact calendar events, N minutes
  before the release, optionally restricted to chosen currencies. Scheduled as
  local notifications straight off the calendar data, so they fire even if the
  app never gets another background slot; every calendar refresh re-plans them
  against Forex Factory's revised times.
- *Breaking headlines* — a background fetch (BGAppRefreshTask) pulls the
  enabled feeds while the app is closed and posts the newest arrivals, capped
  at three per wake so the app never spams its way out of permission.

**Why not real push?** Remote push needs an `aps-environment` entitlement
baked into a signing profile. This app ships as an *unsigned* .ipa — whoever
installs it signs it themselves (AltStore, Sideloadly, a dev certificate), and
a self-signed profile carries no push entitlement. Local notifications plus
background refresh deliver the same two moments that matter — "CPI in 15
minutes" and "ZeroHedge just published" — without a server, an APNs key, or a
paid developer account.

## Building

CI (`.github/workflows/macro.yml`) builds an unsigned `Macro-unsigned.ipa` on
every push that touches `macro/`, uploads it as a workflow artifact, and
publishes it to the repo's rolling `latest` release. Install by signing it
yourself — AltStore and Sideloadly both re-sign on import.

Locally, with Xcode:

```
open macro/ios/Macro.xcodeproj
```

## Tools

Everything resolves paths relative to this folder, so run from anywhere:

- `python3 macro/tools/gen_pbxproj.py` — regenerate the Xcode project from
  what is on disk (run after adding/removing a Swift file); `--check` verifies
  the committed project matches the tree.
- `python3 macro/tools/make_icons.py` — regenerate the app icon.
- `python3 macro/tools/precheck.py` — the pre-push checks CI runs first:
  bracket balance, plist capability keys (including that the BGTaskScheduler
  identifier in Swift and Info.plist agree), feed catalog sanity, workflow
  YAML, project freshness.

## Data sources and their terms

Every endpoint is public and keyless, and none of them promises to stay that
way: Forex Factory's calendar CDN, Stooq CSV, Frankfurter/ECB, and each
outlet's own RSS. The app treats all of them as best-effort — a dead endpoint
shows as a quiet source, never a crash — and the market numbers are
indicative, not tradable. If a feed moves, its address lives in one place
(`Model/FeedSource.swift`), with fallbacks tried in order.
