#!/usr/bin/env python3
"""Fetch the real feeds and trace every article through the pipeline.

This exists because four rounds of plausible fixes shipped without anyone —
me — ever looking at the actual bytes Citizen Free Press serves. The dev
environment cannot reach news hosts, but a CI runner can, so this runs there:
it fetches each source with the app's exact User-Agent and Accept headers, then
pushes every item through the Python mirror of the whole pipeline — sanitize,
parse, date, classify, dedupe, the 12-hour brief window — and prints a verdict
line per article. When a story would be invisible in the app, the line says
which stage would have eaten it.

Run: python3 dispatch/tools/verify_live.py            (needs open egress)
CI:  .github/workflows/dispatch-verify.yml runs it on every change to it.
"""

import os
import sys
import time
import urllib.request
import urllib.error
import xml.etree.ElementTree as ElementTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from feed_reference import (  # noqa: E402
    sanitize, classify, load_lexicon, parse_date, canonical_key,
    plain_text, headline, outbound_link, looks_like_html,
)

# The app's exact headers — HTTP.swift. Verifying with different headers would
# verify a different app.
USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)
ACCEPT = ("application/rss+xml, application/atom+xml, application/xml;q=0.9, "
          "text/xml;q=0.9, */*;q=0.8")

# id, prior, fallback, drops_unsortable(False after the migration), addresses —
# mirrors SourceCatalog.
SOURCES = [
    ("citizenfreepress", "politics", "politics", [
        "https://citizenfreepress.com/feed/",
        "https://citizenfreepress.com/feed/rss/",
        "https://citizenfreepress.com/?feed=rss2",
    ]),
    ("zerohedge", "economics", "economics", [
        "https://feeds.feedburner.com/zerohedge/feed",
        "https://www.zerohedge.com/fullrss2.xml",
    ]),
]

LEXICON = load_lexicon()
PROBLEMS = []


def fetch(url):
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": ACCEPT,
        "Accept-Language": "en-US,en;q=0.9",
    })
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return response.status, response.read(), time.time() - started
    except urllib.error.HTTPError as error:
        return error.code, error.read()[:2000], time.time() - started
    except Exception as error:  # noqa: BLE001 — the point is to report, not die
        return None, str(error).encode(), time.time() - started


def child_text(element, *names):
    for name in names:
        for node in element.iter():
            tag = node.tag.split("}")[-1]
            if tag == name and node.text and node.text.strip():
                return node.text.strip()
    return None


def items_of(root):
    return [node for node in root.iter()
            if node.tag.split("}")[-1] in ("item", "entry")]


def trace(source_id, prior, fallback, payload):
    """Every stage of the pipeline, per article, with the losses named."""
    text = payload.decode("utf-8", errors="replace")
    repaired = sanitize(text)
    try:
        root = ElementTree.fromstring(repaired)
    except ElementTree.ParseError as error:
        PROBLEMS.append("%s: sanitized document does not parse: %s" % (source_id, error))
        print("  PARSE FAILED after sanitize: %s" % error)
        print("  head: %r" % repaired[:300])
        return

    items = items_of(root)
    print("  %d items in the document" % len(items))
    if not items:
        PROBLEMS.append("%s: feed parsed but held zero items" % source_id)
        return

    now = time.time()
    seen_keys = {}
    counts = {"war": 0, "politics": 0, "economics": 0, "fallback": 0,
              "no_date": 0, "dedupe_loss": 0, "stale_sort": 0}

    for index, item in enumerate(items):
        title_raw = child_text(item, "title") or ""
        title = plain_text(title_raw) or headline(plain_text(
            child_text(item, "description") or ""))
        link = child_text(item, "link")
        date_raw = child_text(item, "pubDate", "published", "updated", "date")
        parsed = parse_date(date_raw) if date_raw else None

        topic, _conf, evidence, is_fallback = classify(
            title, "", prior, fallback, LEXICON)

        flags = []
        if parsed is None:
            counts["no_date"] += 1
            flags.append("NO-DATE(sorts to the bottom of every merged list)")
            counts["stale_sort"] += 1
        else:
            age_hours = (now - parsed.timestamp()) / 3600
            if age_hours > 24 * 7:
                flags.append("DATE-ANCIENT(%.0fd — would sort below a week of news)"
                             % (age_hours / 24))
                counts["stale_sort"] += 1

        key = canonical_key(link) if link else "title:" + title.lower().strip()
        if key in seen_keys:
            counts["dedupe_loss"] += 1
            flags.append("DEDUPE-COLLISION(with item %d — one row for two posts)"
                         % seen_keys[key])
        else:
            seen_keys[key] = index

        if is_fallback:
            counts["fallback"] += 1
        else:
            counts[topic] += 1

        print("  [%02d] %-9s %s %s" % (
            index,
            (topic or "none") + ("*" if is_fallback else ""),
            ("%5.1fh" % ((now - parsed.timestamp()) / 3600)) if parsed else " ???h",
            title[:88],
        ))
        for flag in flags:
            print("       ^^ %s" % flag)
        if date_raw and parsed is None:
            PROBLEMS.append("%s: date %r did not parse" % (source_id, date_raw))
            print("       ^^ RAW DATE: %r" % date_raw)

    print("  ---- %s: war %d · politics %d · economics %d · by-default %d"
          % (source_id, counts["war"], counts["politics"], counts["economics"],
             counts["fallback"]))
    if counts["no_date"]:
        PROBLEMS.append("%s: %d items with unparseable dates" % (source_id, counts["no_date"]))
    if counts["dedupe_loss"]:
        PROBLEMS.append("%s: %d items lost to dedupe collisions"
                        % (source_id, counts["dedupe_loss"]))


def main():
    for source_id, prior, fallback, addresses in SOURCES:
        print("=" * 96)
        print(source_id)
        got = False
        for address in addresses:
            status, payload, elapsed = fetch(address)
            kind = ("html" if looks_like_html(payload.decode("utf-8", "replace"))
                    else "feed?")
            print("  %s -> %s  %d bytes  %.1fs  looks like: %s"
                  % (address, status, len(payload), elapsed, kind))
            if status == 200 and kind != "html":
                trace(source_id, prior, fallback, payload)
                got = True
                break
            if status == 200 and kind == "html":
                print("       200 but an HTML page — exactly the case the app now "
                      "treats as a failure. head: %r"
                      % payload[:160])
        if not got:
            PROBLEMS.append("%s: no address yielded a feed" % source_id)

    print("=" * 96)
    if PROBLEMS:
        print("FINDINGS (%d):" % len(PROBLEMS))
        for problem in PROBLEMS:
            print("  - " + problem)
        # Findings are the point, not a failure of this script.
        return
    print("all sources fetched, parsed, dated and classified cleanly")


if __name__ == "__main__":
    main()
