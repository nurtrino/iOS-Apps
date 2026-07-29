#!/usr/bin/env python3
"""Assertions for Dispatch's parsing layer.

Run: python3 dispatch/tools/test_feeds.py

The fixtures are hand-constructed against the shapes these sources are known to
emit — WordPress RSS with `content:encoded` and lazy-loaded images, Atom with
`link href`, RSS 1.0/RDF, Telegram's widget markup, Steam's BBCode. This build
environment's egress policy blocks every one of those hosts, so nothing here was
scraped live. Anything that turns out to disagree with a real payload should be
corrected against a real sample and the Swift updated in step.

What these tests are really defending is a specific failure mode: a feed reader
does not crash when its parser is wrong, it just quietly shows an empty section.
Every case below is one where the naive implementation returns nothing, or
returns something subtly wrong, and nobody would notice for a week.
"""

import os
import sys
import xml.etree.ElementTree as ElementTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from feed_reference import (  # noqa: E402
    sanitize, rewrite_entities, decode_entities, plain_text, strip_tags,
    collapse_whitespace, attribute_value, first_image_url, tag_name,
    remove_opaque_sections, canonical_key, headline, message_chunks,
    balanced_div, parse_telegram, normalize_channel, normalize_handle,
    steam_html, parse_date, replacement, last_attribute_value,
)

FAILURES = []
CHECKS = 0


def check(label, actual, expected):
    global CHECKS
    CHECKS += 1
    if actual != expected:
        FAILURES.append("%s\n     expected: %r\n     actual:   %r" % (label, expected, actual))


def check_true(label, actual):
    check(label, bool(actual), True)


# --- XML repair -------------------------------------------------------------
#
# This is the section that decides whether the app has any content at all. Every
# case here makes XMLParser abort with "undefined entity" or "not well-formed"
# and return zero items — which the UI can only render as "this source is
# quiet".

check("a bare ampersand is escaped",
      rewrite_entities("Q&A with the Fed"), "Q&amp;A with the Fed")

check("&nbsp; becomes a numeric reference",
      rewrite_entities("hard&nbsp;space"), "hard&#160;space")

check("&mdash; becomes a numeric reference",
      rewrite_entities("a&mdash;b"), "a&#8212;b")

check("XML's own five are left alone",
      rewrite_entities("&amp;&lt;&gt;&quot;&apos;"), "&amp;&lt;&gt;&quot;&apos;")

check("a valid numeric reference is left alone",
      rewrite_entities("&#8212; and &#x2014;"), "&#8212; and &#x2014;")

check("an unknown named entity keeps its text but loses its ampersand",
      rewrite_entities("&nosuchthing;"), "&amp;nosuchthing;")

check("an ampersand in a query string is escaped",
      rewrite_entities("<link>http://x.com/?a=1&b=2</link>"),
      "<link>http://x.com/?a=1&amp;b=2</link>")

# A semicolon much later in the sentence is not the end of an entity. Without
# the length cap, "Smith & Wesson; the company" swallows 20 characters as an
# entity name and silently deletes them.
check("a distant semicolon does not make an entity",
      rewrite_entities("Smith & Wesson; the company"),
      "Smith &amp; Wesson; the company")

check("a control character is dropped outright",
      rewrite_entities("before\x0bafter"), "beforeafter")

check("tab, newline and carriage return survive",
      rewrite_entities("a\tb\nc\rd"), "a\tb\nc\rd")

check("a numeric reference to a forbidden character is dropped",
      rewrite_entities("x&#12;y"), "xy")

check("the declared encoding is rewritten to UTF-8",
      sanitize('<?xml version="1.0" encoding="ISO-8859-1"?><rss/>'),
      '<?xml version="1.0" encoding="UTF-8"?><rss/>')

check("a leading BOM is stripped",
      sanitize('﻿<?xml version="1.0"?><rss/>'),
      '<?xml version="1.0"?><rss/>')

# The repaired document must actually parse. This is the assertion that matters
# most: everything above is a means to this end.
DIRTY_RSS = """<?xml version="1.0" encoding="ISO-8859-1"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel>
<title>ZeroHedge</title>
<link>https://www.zerohedge.com</link>
<item>
  <title>Fed Holds Rates, Q&amp;A Turns Testy</title>
  <link>https://www.zerohedge.com/markets/fed-holds?utm_source=feed&amp;utm_medium=rss</link>
  <guid isPermaLink="false">node/12345</guid>
  <description>Powell&nbsp;said the committee&rsquo;s view had not changed &mdash; much.</description>
  <content:encoded><![CDATA[<p>Full body with an <a href="/x">internal link</a>.</p>
  <img src="https://cdn.zerohedge.com/hero.jpg" />]]></content:encoded>
  <pubDate>Tue, 28 Jul 2026 18:30:00 GMT</pubDate>
  <dc:creator>Tyler Durden</dc:creator>
</item>
</channel>
</rss>"""

try:
    ROOT = ElementTree.fromstring(sanitize(DIRTY_RSS))
    PARSED_OK = True
except ElementTree.ParseError as error:
    ROOT = None
    PARSED_OK = False
    FAILURES.append("a feed with HTML entities and a bad encoding failed to parse: %s" % error)
    CHECKS += 1

if PARSED_OK:
    ITEM = ROOT.find("./channel/item")
    check("the repaired feed yields an item", ITEM is not None, True)
    check("the title survives the repair",
          ITEM.findtext("title"), "Fed Holds Rates, Q&A Turns Testy")
    check("&rsquo; and &mdash; round-trip to real characters",
          ITEM.findtext("description"),
          "Powell said the committee’s view had not changed — much.")
    check("dc:creator is readable",
          ITEM.findtext("{http://purl.org/dc/elements/1.1/}creator"), "Tyler Durden")
    check("content:encoded survives as markup",
          "<a href=\"/x\">internal link</a>" in
          ITEM.findtext("{http://purl.org/rss/1.0/modules/content/}encoded"), True)

ATOM = """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>The War Zone</title>
  <link rel="self" href="https://www.twz.com/feed"/>
  <link rel="alternate" href="https://www.twz.com"/>
  <entry>
    <title>Carrier Deploys</title>
    <link rel="alternate" type="text/html" href="https://www.twz.com/sea/carrier"/>
    <id>tag:twz.com,2026:9910</id>
    <summary>A summary with a &amp; in it.</summary>
    <published>2026-07-28T12:00:00Z</published>
    <author><name>Staff</name></author>
  </entry>
</feed>"""

try:
    ATOM_ROOT = ElementTree.fromstring(sanitize(ATOM))
    ATOM_ENTRY = ATOM_ROOT.find("{http://www.w3.org/2005/Atom}entry")
    check("an Atom entry parses after repair", ATOM_ENTRY is not None, True)
except ElementTree.ParseError as error:
    CHECKS += 1
    FAILURES.append("Atom failed to parse: %s" % error)


# --- Markup to text ---------------------------------------------------------

check("tags are stripped and entities decoded",
      plain_text("<p>Powell&rsquo;s &ldquo;pause&rdquo;</p>"),
      "Powell’s “pause”")

check("a script block is removed with its contents",
      plain_text("<p>Real text</p><script>var x = 1 < 2;</script><p>More</p>"),
      "Real text\nMore")

check("a style block is removed with its contents",
      plain_text("<style>.a{color:red}</style><p>Body</p>"), "Body")

check("an HTML comment is removed",
      plain_text("<p>A</p><!-- hidden --><p>B</p>"), "A\nB")

# "<sect" must not match "<section". Getting this wrong deletes the entire
# article body of any site that wraps content in <section>.
check("a section tag is not mistaken for a removed tag",
      plain_text("<section><p>Kept</p></section>"), "Kept")

check("<br> becomes a newline", plain_text("one<br>two"), "one\ntwo")

check("list items get bullets", plain_text("<ul><li>one</li><li>two</li></ul>"),
      "• one\n• two")

check("runs of whitespace collapse to one space",
      collapse_whitespace("a   \t  b"), "a b")

# A single newline, not two. `</p><p>` is one paragraph boundary that emits two
# breaks, and a `<ul>` of two items emits five — so a faithful count produces a
# dek made mostly of blank lines.
check("a run of newlines collapses to one",
      collapse_whitespace("a\n\n\n\n\nb"), "a\nb")

check("leading whitespace is dropped", collapse_whitespace("   \n  hello"), "hello")

check("a stray less-than in prose is kept",
      plain_text("5 < 6 is true"), "5 < 6 is true")

check("an unterminated tag does not eat the document",
      plain_text("<p>text <b>bold"), "text bold")

check("the tag name of a closing tag drops the slash", tag_name("/div"), "div")
check("the tag name stops at the first space", tag_name('img src="x"'), "img")

check("an unterminated script section removes the rest",
      remove_opaque_sections("<p>A</p><script>never closed"), "<p>A</p>")


# --- Attributes and images --------------------------------------------------
#
# The attribute matcher has to distinguish `src` from `data-src`. It does not
# sound like it matters until you notice every WordPress theme puts a grey
# placeholder in `src` and the real photo in `data-src`.

check("src is read", attribute_value("src", 'img src="a.jpg"'), "a.jpg")

check("src does not match data-src",
      attribute_value("src", 'img data-src="real.jpg"'), None)

check("data-src is read when asked for",
      attribute_value("data-src", 'img data-src="real.jpg" src="blank.gif"'), "real.jpg")

check("single quotes work", attribute_value("src", "img src='a.jpg'"), "a.jpg")

check("an unquoted value works", attribute_value("src", "img src=a.jpg width=10"), "a.jpg")

check("spaces around the equals sign are tolerated",
      attribute_value("src", 'img src = "a.jpg"'), "a.jpg")

check("an entity in an attribute is decoded",
      attribute_value("href", 'a href="/x?a=1&amp;b=2"'), "/x?a=1&b=2")

check("a bare attribute with no value is skipped",
      attribute_value("src", 'img async src="real.jpg"'), "real.jpg")

check("the lazy-loaded image wins over the placeholder",
      first_image_url('<img src="blank.gif" data-src="https://cdn/real.jpg">'),
      "https://cdn/real.jpg")

check("a data URI is skipped in favour of the next image",
      first_image_url('<img src="data:image/gif;base64,R0lGOD"><img src="https://cdn/real.jpg">'),
      "https://cdn/real.jpg")

check("a feedburner tracking pixel is skipped",
      first_image_url('<img src="http://feeds.feedburner.com/~ff/x?i=1">'
                      '<img src="https://cdn/real.jpg">'),
      "https://cdn/real.jpg")

check("a 1x1 spacer is skipped",
      first_image_url('<img src="https://cdn/1x1.gif"><img src="https://cdn/real.jpg">'),
      "https://cdn/real.jpg")

check("no image returns nothing", first_image_url("<p>text</p>"), None)


# --- Canonical URLs ---------------------------------------------------------
#
# Two links to one story must collide, or a merged section shows the same
# headline twice.

check("tracking parameters are dropped",
      canonical_key("https://www.zerohedge.com/markets/story?utm_source=rss&utm_medium=feed"),
      "zerohedge.com/markets/story")

check("www and a trailing slash do not change identity",
      canonical_key("https://www.twz.com/air/story/"),
      canonical_key("https://twz.com/air/story"))

check("a fragment does not change identity",
      canonical_key("https://x.com/a#comments"), canonical_key("https://x.com/a"))

check("a real query parameter is kept",
      canonical_key("https://x.com/a?id=7"), "x.com/a?id=7")

check("query parameters are order-insensitive",
      canonical_key("https://x.com/a?b=2&a=1"), canonical_key("https://x.com/a?a=1&b=2"))

check("different stories do not collide",
      canonical_key("https://x.com/a") == canonical_key("https://x.com/b"), False)


# --- Headlines from bodyless posts ------------------------------------------
#
# Telegram and X posts have no title. These become the headline in the row.

check("a short post is its own headline", headline("Missile strike reported."),
      "Missile strike reported.")

check("the first line wins when it is long enough",
      headline("BREAKING: strike reported\nMore detail follows in this paragraph."),
      "BREAKING: strike reported")

# A one-word first line is a label, not a headline — falling back to the
# sentence gives a row worth reading.
check("a too-short first line is not used alone",
      headline("URGENT\nA long sentence that carries the actual news content here."),
      "URGENT\nA long sentence that carries the actual news content here.")

check("a long post is cut at a sentence",
      headline("First sentence ends here. " + "x" * 200),
      "First sentence ends here.")

check("a long post with no sentence break is cut at a word",
      headline("word " * 60).endswith("…"), True)

check("an empty post gets a placeholder", headline("   "), "Untitled")


# --- Telegram ---------------------------------------------------------------

TELEGRAM = """<html><body>
<div class="tgme_widget_message_wrap">
 <div class="tgme_widget_message" data-post="wfwitness/2360">
  <a class="tgme_widget_message_photo_wrap"
     style="background-image:url('https://cdn4.telesco.pe/file/one.jpg')"></a>
  <div class="tgme_widget_message_text js-message_text">First post with a
   <a href="https://example.com">link</a> and <b>bold</b>.</div>
  <div class="tgme_widget_message_footer">
   <time datetime="2026-07-28T09:15:00+00:00"></time>
  </div>
 </div>
</div>
<div class="tgme_widget_message_wrap">
 <div class="tgme_widget_message" data-post="wfwitness/2361">
  <div class="tgme_widget_message_reply">
   <div class="tgme_widget_message_text js-message_reply_text">Quoted older post</div>
  </div>
  <div class="tgme_widget_message_text js-message_text">Second post
   <div class="spoiler">with a nested div</div> and a tail.</div>
  <div class="tgme_widget_message_footer">
   <time datetime="2026-07-28T11:00:00+00:00"></time>
  </div>
 </div>
</div>
</body></html>"""

check("each message becomes one chunk", len(message_chunks(TELEGRAM)), 2)

POSTS = parse_telegram(TELEGRAM)
check("both messages become articles", len(POSTS), 2)
check("the post id becomes the article id", POSTS[0]["id"], "tg|wfwitness/2360")
check("the post links to itself", POSTS[0]["link"], "https://t.me/wfwitness/2360")
check("the background image is found",
      POSTS[0]["image"], "https://cdn4.telesco.pe/file/one.jpg")
check("inline markup is flattened to text",
      POSTS[0]["summary"], "First post with a link and bold.")
check("the footer timestamp is used", POSTS[0]["published"], "2026-07-28T09:15:00+00:00")

# The reply preview uses `tgme_widget_message_text` too. Matching that broad
# class instead of `js-message_text` pulls the quoted post in as if the channel
# had written it.
check("a reply preview is not mistaken for the post",
      "Quoted older post" in POSTS[1]["summary"], False)

# Telegram wraps spoilers in their own div. Stopping at the first </div>
# truncates every post that contains one.
check("a nested div does not truncate the post",
      POSTS[1]["summary"], "Second post\nwith a nested div\nand a tail.")

check("the last datetime in a chunk wins",
      last_attribute_value("datetime", '<time datetime="A"></time><time datetime="B"></time>'),
      "B")

check("an unbalanced div returns what is there",
      balanced_div('<div class="js-message_text">tail with no close', "js-message_text"),
      "tail with no close")

# A service message — "channel photo updated" — has neither text nor a photo.
check("a message with no text and no image is skipped",
      len(parse_telegram('<div data-post="c/1"><div class="tgme_widget_message_service">'
                         'joined</div></div>')),
      0)

check("a bare channel name is unchanged", normalize_channel("wfwitness"), "wfwitness")
check("an @ is stripped", normalize_channel("@wfwitness"), "wfwitness")
check("a t.me URL yields the channel", normalize_channel("https://t.me/wfwitness"), "wfwitness")
check("a preview URL yields the channel", normalize_channel("t.me/s/wfwitness"), "wfwitness")
check("a post URL yields the channel", normalize_channel("https://t.me/wfwitness/2361"), "wfwitness")


# --- X handles --------------------------------------------------------------

check("a bare handle is unchanged", normalize_handle("Wario64"), "Wario64")
check("an @ is stripped from a handle", normalize_handle("@zerohedge"), "zerohedge")
check("an x.com URL yields the handle", normalize_handle("https://x.com/zerohedge"), "zerohedge")
check("a twitter.com URL yields the handle",
      normalize_handle("https://twitter.com/Wario64?s=20"), "Wario64")
check("underscores survive", normalize_handle("@Genki_JPN"), "Genki_JPN")
check("punctuation is dropped", normalize_handle("@bad handle!"), "bad")


# --- Steam BBCode -----------------------------------------------------------

check("bold becomes strong", steam_html("[b]Patch 1.2[/b]"), "<strong>Patch 1.2</strong>")

check("a labelled url becomes an anchor",
      steam_html("[url=https://example.com]notes[/url]"),
      '<a href="https://example.com">notes</a>')

check("a bare url becomes an anchor to itself",
      steam_html("[url]https://example.com[/url]"),
      '<a href="https://example.com">https://example.com</a>')

check("an image becomes an img tag",
      steam_html("[img]https://cdn/shot.png[/img]"),
      '<img src="https://cdn/shot.png">')

check("a list becomes a real list",
      steam_html("[list][*]one[*]two[/list]"),
      "<ul><li>one<li>two</ul>")

check("newlines become breaks", steam_html("line one\nline two"), "line one<br>line two")

# External blog items come through the same field already as HTML. Running
# BBCode rules over them does nothing useful and can mangle a literal bracket.
check("html contents are passed through untouched",
      steam_html("<p>Already HTML with [brackets]</p>"),
      "<p>Already HTML with [brackets]</p>")

check("bbcode renders to readable text end to end",
      plain_text(steam_html("[h1]Update[/h1]\n[list][*]Fixed a crash[*]Rebalanced[/list]")),
      "Update\n• Fixed a crash\n• Rebalanced")


# --- Dates ------------------------------------------------------------------
#
# An unparsed date sorts to the bottom of every merged feed, so a source with a
# format nobody handles looks like it stopped updating.

check("RFC 822 with a numeric offset parses",
      parse_date("Tue, 28 Jul 2026 18:30:00 +0000").isoformat(), "2026-07-28T18:30:00+00:00")

check("GMT is treated as +0000",
      parse_date("Tue, 28 Jul 2026 18:30:00 GMT").isoformat(), "2026-07-28T18:30:00+00:00")

check("a US zone abbreviation parses",
      parse_date("Tue, 28 Jul 2026 14:30:00 EDT").isoformat(), "2026-07-28T14:30:00-04:00")

check("ISO 8601 with Z parses",
      parse_date("2026-07-28T12:00:00+0000").isoformat(), "2026-07-28T12:00:00+00:00")

check("ISO 8601 with fractional seconds parses",
      parse_date("2026-07-28T12:00:00.500+0000").isoformat(), "2026-07-28T12:00:00.500000+00:00")

check("a date-only stamp parses",
      parse_date("2026-07-28").isoformat(), "2026-07-28T00:00:00+00:00")

check("a Unix timestamp parses",
      parse_date("1785000000").isoformat(), "2026-07-25T17:20:00+00:00")

check("nonsense returns nothing", parse_date("not a date"), None)
check("an empty string returns nothing", parse_date("   "), None)


# --- Entity table sanity ----------------------------------------------------

check("a decimal reference resolves", replacement("#8212"), "—")
check("a hex reference resolves", replacement("#x2014"), "—")
check("an out-of-range reference resolves to nothing", replacement("#1114112"), None)
check("a surrogate resolves to nothing", replacement("#55296"), None)
check("an unknown name resolves to nothing", replacement("nope"), None)

check("decoding is idempotent for plain text", decode_entities("plain"), "plain")
check("a bare ampersand survives decoding", decode_entities("Q&A"), "Q&A")
check("an unknown entity survives decoding", decode_entities("&nope;"), "&nope;")


# --- Report -----------------------------------------------------------------

if FAILURES:
    print("FAILED %d of %d checks\n" % (len(FAILURES), CHECKS))
    for failure in FAILURES:
        print("  - " + failure)
    sys.exit(1)

print("all %d feed parsing checks passed" % CHECKS)
