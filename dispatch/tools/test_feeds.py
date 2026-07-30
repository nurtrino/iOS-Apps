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
    load_lexicon, classify, normalise, is_local_host, normalized_host,
    links_in, outbound_link,
    expand_placeholders, strip_remaining_tags, is_predominantly_latin,
    summary_constants, stable_hash_hex, brief_input_key, summary_prompt,
    summary_bullets, merge_articles,
    fred_rows, fred_observations, nearest_observation, percent_change,
    classifier_constants, classifier_prompt, parse_decisions, one_line,
    youtube_id, looks_like_html,
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


# --- Topic classification ---------------------------------------------------
#
# The lexicon is read out of TopicLexicon.swift, so these run against the table
# the app actually ships. A term added to the app is a term these tests see.
#
# What is being defended: a story landing in the wrong section is the failure
# nobody reports, because it does not look like a bug — it looks like the feed
# being quiet. The ambiguous cases below are the ones a naive keyword matcher
# gets wrong, and each is a word that genuinely belongs to two topics.

LEXICON = load_lexicon()


def topic_of(title, body="", prior=None, fallback="politics"):
    return classify(title, body, prior, fallback, LEXICON)[0]


def verdict_of(title, body="", prior=None, fallback="politics"):
    return classify(title, body, prior, fallback, LEXICON)


def saw_nothing(title, body="", prior="politics", fallback="politics"):
    """True when no term matched, so the lexicon is guessing.

    This used to be `filed_or_dropped`, and the rename is the whole point of a
    change made after real headlines started disappearing: a lexicon with no word
    for a story must not be the thing that hides it. It falls back to the source
    default and says it is guessing; deciding a story fits nowhere is the model's
    job now.
    """
    return classify(title, body, prior, fallback, LEXICON)[3]


def lexicon_topic(title, body="", prior="politics", fallback="politics"):
    return classify(title, body, prior, fallback, LEXICON)[0]


check("the lexicon parses out of the Swift", len(LEXICON), 3)
check_true("every topic has a substantial term list",
           all(len(terms) > 60 for terms in LEXICON.values()))

# No term should appear in two topics with the same weight — that is a term
# doing no work, and usually a sign it wanted to be a phrase.
_SHARED = set(t for t, _ in LEXICON["war"]) & set(t for t, _ in LEXICON["economics"])
check("war and economics share no bare terms", sorted(_SHARED), [])


# --- Unambiguous war --------------------------------------------------------

check("an airstrike headline is war",
      topic_of("Israeli airstrike kills Hezbollah commander in southern Lebanon"), "war")

check("a drone barrage is war",
      topic_of("Russia launches largest drone barrage of the war on Kyiv"), "war")

check("a counteroffensive is war",
      topic_of("Ukraine counteroffensive stalls near Zaporizhzhia"), "war")

check("a carrier deployment is war",
      topic_of("Pentagon confirms carrier strike group deployed to the Red Sea"), "war")


# --- Unambiguous politics ---------------------------------------------------

check("a Supreme Court story is politics",
      topic_of("Supreme Court agrees to hear challenge to executive order", prior="politics"),
      "politics")

check("a confirmation hearing is politics",
      topic_of("Senate Republicans block confirmation hearing for nominee", prior="politics"),
      "politics")

check("a House investigation is politics",
      topic_of("House Democrats launch investigation into deportation flights", prior="politics"),
      "politics")


# --- Unambiguous economics --------------------------------------------------

check("a CPI print is economics",
      topic_of("CPI comes in hotter than expected as inflation reaccelerates", prior="economics"),
      "economics")

check("a Fed decision is economics",
      topic_of("Fed holds rates steady, Powell signals no cuts until inflation cools",
               prior="economics"),
      "economics")

check("an index close is economics",
      topic_of("S&P 500 closes at record high as Treasury yields fall", prior="economics"),
      "economics")

check("a bitcoin move is economics",
      topic_of("Bitcoin tops $100,000 as ETF inflows accelerate", prior="economics"),
      "economics")


# --- The words that belong to two topics ------------------------------------
#
# Each of these is a case where matching the bare word gets it wrong, and the
# phrase in the lexicon is what saves it.

check("an air strike is war, not a labour dispute",
      topic_of("Air strike destroys ammunition depot near Donetsk"), "war")

check("a strike authorization is economics, not war",
      topic_of("Autoworkers vote to authorize strike at three plants", prior="economics"),
      "economics")

check("a UAW walkout is economics",
      topic_of("UAW walkout enters second week as talks stall", prior="economics"), "economics")

check("the West Bank is war, not banking",
      topic_of("West Bank raid leaves several dead"), "war")

check("a central bank is economics, not war",
      topic_of("Central bank holds rates as inflation cools", prior="economics"), "economics")

check("tariffs are economics even on a political outlet",
      topic_of("Trump announces new tariffs on Chinese imports", prior="politics"), "economics")

check("a campaign rally is politics, not a market rally",
      topic_of("Thousands turn out for campaign rally in Ohio", prior="politics"), "politics")

# A Houthi attack moves oil, but on the headline alone the war vocabulary is
# overwhelming and War is where someone monitoring the situation expects it.
check("a Red Sea attack is war even on a markets outlet",
      topic_of("Oil surges after Houthi attack on tanker in Red Sea", prior="economics"), "war")


# --- Weighting and fallbacks ------------------------------------------------

check("the headline outweighs the body",
      topic_of("Missile strike on Kharkiv",
               body="Traders said the stock market and inflation outlook were unchanged.",
               prior="economics"),
      "war")

_LOW = verdict_of("Local bakery wins an award for its sourdough", prior="politics")
check("a story with no signal falls back to the source default", _LOW[0], "politics")
check("a fallback is reported as one", _LOW[3], True)
check("a fallback has no confidence", _LOW[1], 0.0)

_STRONG = verdict_of("Airstrike destroys warship in the Red Sea")
check("a decisive call is confident", _STRONG[1], 1.0)
check("a decisive call is not a fallback", _STRONG[3], False)
check_true("a decisive call cites its evidence", len(_STRONG[2]) > 0)

# The prior is a nudge, not a veto: it must break a tie without dragging an
# obvious battlefield report out of War.
check("the source prior cannot override a strong signal",
      topic_of("Artillery duel intensifies along the frontline", prior="economics"), "war")

# This one reads like a tie-break but is really the fallback: "policy" alone is
# below the threshold, so nothing was asserted and the source default stands. The
# genuine tie-break is tested further down, where both topics clear on evidence.
check("a story with only a weak word takes the source default",
      topic_of("Officials weigh new policy", prior="economics", fallback="economics"),
      "economics")


# --- The corpus: does the filing actually work on real source output? -------
#
# The cases above are unit tests of the tricky parts. This is the different
# question — whether the whole thing works on the mixed output a general outlet
# actually publishes — so it is a run of headlines in the shape and register each
# source really uses, scored the way the app scores them, and counted.
#
# It found three real gaps the unit tests could not, all the same failure: no
# lexicon term matched *at all*, so the story fell back to the source default and
# a carrier movement filed itself under Markets. Anything that scores zero is
# invisible, which is why the count below is asserted rather than eyeballed:
# "carrier strike group", "explosion" and bare "gold" are in the lexicon because
# this list caught their absence.
#
# The two sources are tested differently on purpose. ZeroHedge syndicates full
# text, so the classifier gets a body. Citizen Free Press posts links: title
# only, often five words, no body at all — the harder case by far, and the one
# that produces most of the volume.

# (title, body, expected)
ZEROHEDGE_CORPUS = [
    ("Israel Strikes Hezbollah Targets In Southern Lebanon After Rocket Barrage",
     "The IDF said it hit command centers in response to overnight rocket fire.", "war"),
    ("Russia Launches Largest Drone Barrage Of The War On Kyiv",
     "Ukrainian air defense claimed to have downed most of the incoming drones.", "war"),
    ("US Carrier Strike Group Redeploys To Eastern Mediterranean",
     "The Pentagon confirmed the movement of the carrier and its escorts.", "war"),
    ("Houthis Claim Attack On Tanker In Red Sea",
     "CENTCOM said a missile was intercepted near the vessel.", "war"),
    ("China Fires Hypersonic Anti-Ship Missile From Smaller Destroyer",
     "State media released footage of the launch.", "war"),
    ("Core CPI Comes In Hotter Than Expected As Shelter Costs Reaccelerate",
     "Consumer price inflation rose more than economists forecast last month.", "economics"),
    ("Futures Slide As 10-Year Yield Tops 4.5% Ahead Of Powell Testimony",
     "Treasury yields climbed and equities fell before the Fed chair speaks.", "economics"),
    ("Gold Price Hits Record High As Dollar Index Slumps",
     "Bullion rallied for a fourth session as the dollar weakened.", "economics"),
    ("Nonfarm Payrolls Miss Badly, Unemployment Rate Jumps To 4.6%",
     "The labor market cooled sharply according to the BLS report.", "economics"),
    ("Bitcoin Tumbles Below $90,000 In Sudden Selloff",
     "Crypto markets saw heavy liquidations overnight.", "economics"),
    ("Fed Holds Rates Steady But Signals Two Cuts This Year",
     "The FOMC statement left the target range unchanged.", "economics"),
    ("Supreme Court Agrees To Hear Challenge To Executive Order On Deportations",
     "The justices will consider the scope of presidential authority.", "politics"),
    ("Senate Democrats Block Spending Bill As Shutdown Deadline Nears",
     "Lawmakers remain deadlocked with days to go.", "politics"),
    ("House Republicans Subpoena Attorney General Over Withheld Documents",
     "The committee hearing is scheduled for next week.", "politics"),
    ("Poll Shows Approval Rating Slipping Among Independents",
     "The survey of registered voters was conducted last week.", "politics"),
]

# (title, expected) — no body, because these posts have none.
CFP_CORPUS = [
    ("Massive explosion reported in Riyadh", "war"),
    ("Israel strikes Gaza overnight", "war"),
    ("Russian missile hits apartment block in Kharkiv", "war"),
    ("US airstrike kills ISIS commander in Syria", "war"),
    ("Pentagon confirms troop deployment to the region", "war"),
    ("Drone swarm intercepted over Kyiv", "war"),
    ("Trump signs executive order on offshore drilling", "politics"),
    ("Senate confirms new attorney general", "politics"),
    ("Federal judge blocks deportation flights", "politics"),
    ("Governor declares state of emergency", "politics"),
    ("Protests erupt outside the White House", "politics"),
    ("Democrats introduce gun control bill", "politics"),
    ("Gold hits record high", "economics"),
    ("Fed cuts rates by 25 basis points", "economics"),
    ("Stocks tumble in worst selloff since April", "economics"),
    ("Mortgage rate falls below 6%", "economics"),
    ("Bitcoin crashes", "economics"),
    ("Layoffs announced at major retailer", "economics"),
]

_MISFILED = []
for _title, _body, _want in ZEROHEDGE_CORPUS:
    _got = topic_of(_title, body=_body, prior="economics", fallback="economics")
    if _got != _want:
        _MISFILED.append("ZeroHedge %r → %s, wanted %s" % (_title, _got, _want))
for _title, _want in CFP_CORPUS:
    _got = topic_of(_title, prior="politics", fallback="politics")
    if _got != _want:
        _MISFILED.append("CFP %r → %s, wanted %s" % (_title, _got, _want))

check("every corpus headline files where it belongs", _MISFILED, [])
check_true("the corpus is big enough to mean something",
           len(ZEROHEDGE_CORPUS) + len(CFP_CORPUS) >= 30)

# Nothing in the corpus should be reaching its section by fallback. A fallback is
# the classifier admitting it saw nothing, and on a mixed outlet that means the
# section is being filled by the source's default rather than by the story.
_FELL_BACK = [t for t, b, _ in ZEROHEDGE_CORPUS
              if verdict_of(t, body=b, prior="economics", fallback="economics")[3]]
_FELL_BACK += [t for t, _ in CFP_CORPUS
               if verdict_of(t, prior="politics", fallback="politics")[3]]
check("no corpus headline needs the fallback", _FELL_BACK, [])

# The terms added because of the corpus have to keep earning their place, and
# the ambiguous readings of them have to stay wrong.
check("a bare carrier strike group is war",
      topic_of("Carrier strike group ordered to the eastern Mediterranean"), "war")
# A bare explosion is deliberately *below* the threshold. At a weight that
# cleared it alone, every industrial accident and gas-line fire filed itself
# under War; paired with somewhere in the theatre it is unambiguous.
check("an explosion alone is not enough",
      verdict_of("Explosion reported near the airport")[3], True)
check("an explosion somewhere in the theatre is war",
      topic_of("Explosion rocks Beirut suburb"), "war")
check("bare gold is economics",
      topic_of("Gold jumps to a record", prior="economics"), "economics")

# "Blast" is deliberately *not* in the lexicon: on these outlets it is how a
# politician criticising another politician is spelled.
check("a politician blasting another is not a war story",
      topic_of("Trump blasts Democrats over spending bill", prior="politics"), "politics")


# --- The aggregator corpus: sort it or skip it -------------------------------
#
# Citizen Free Press is the volume problem. Dozens of link posts a day, title
# only, five to ten words, and the mix is politics and crime and foreign news
# *and* a bear in a supermarket. Two things have to be true for that to work: the
# vocabulary has to reach most of it, and the part it genuinely cannot place has
# to be dropped rather than filed under the source's default.
#
# Before this corpus existed, 24 of these 73 matched nothing at all and were
# silently filed under Politics. That is the failure the user actually sees: a
# section that looks like news but is a third guesswork. 114 terms went in.
#
# The ten `None` cases are as load-bearing as the rest. They are why bare
# "grocery" is not an economics term and why "explosion" scores below the
# threshold on its own.

# (title, expected topic or None for "no section")
AGGREGATOR_CORPUS = [
    ("Trump signs executive order on offshore drilling", "politics"),
    ("Senate confirms new attorney general", "politics"),
    ("Federal judge blocks deportation flights", "politics"),
    ("Governor declares state of emergency", "politics"),
    ("Protests erupt outside the White House", "politics"),
    ("Democrats introduce gun control bill", "politics"),
    ("Speaker announces vote on the spending package", "politics"),
    ("Newsom vetoes housing bill", "politics"),
    ("DeSantis signs school choice expansion", "politics"),
    ("Poll: independents souring on both parties", "politics"),
    ("Mayor announces re-election bid", "politics"),
    ("State legislature overrides veto", "politics"),
    ("Supreme Court takes up gun case", "politics"),
    ("Appeals court reinstates travel restrictions", "politics"),
    ("Congressman announces retirement", "politics"),
    ("Whistleblower testifies before committee", "politics"),
    ("Pentagon nominee grilled at hearing", "politics"),
    ("Recount ordered in state senate race", "politics"),
    ("Judge orders release of grand jury records", "politics"),

    # Crime, courts and immigration. There are four sections and no "crime"
    # among them, so these belong with the law and the people arguing about it.
    ("Illegal alien charged with murder in Texas", "politics"),
    ("ICE arrests 200 in weekend sweep", "politics"),
    ("Border Patrol reports record crossings", "politics"),
    ("Cartel gunmen kill police chief", "politics"),
    ("Sanctuary city releases suspect", "politics"),
    ("Jury convicts former mayor on bribery charges", "politics"),
    ("Prosecutors seek life sentence", "politics"),
    ("Sheriff refuses to enforce new gun law", "politics"),
    ("DOJ opens civil rights investigation", "politics"),
    ("Fentanyl bust nets 40 pounds", "politics"),

    ("School board votes to remove books", "politics"),
    ("University president resigns after hearing", "politics"),
    ("CNN ratings hit new low", "politics"),
    ("Teachers union sues over new curriculum", "politics"),
    ("Trans athlete ruling sparks backlash", "politics"),
    ("Publisher cancels author over tweet", "politics"),

    ("Massive explosion reported in Riyadh", "war"),
    ("Israel strikes Gaza overnight", "war"),
    ("Russian missile hits apartment block in Kharkiv", "war"),
    ("US airstrike kills ISIS commander in Syria", "war"),
    ("Pentagon confirms troop deployment to the region", "war"),
    ("Drone swarm intercepted over Kyiv", "war"),
    ("Iran announces new uranium enrichment site", "war"),
    ("Netanyahu vows response", "war"),
    ("North Korea fires missile over Japan", "war"),
    ("Taiwan scrambles jets as Chinese aircraft cross the line", "war"),
    ("Convoy ambushed outside Kabul", "war"),
    ("Putin threatens retaliation", "war"),
    ("Houthi attack closes shipping lane", "war"),
    ("Explosion rocks Beirut suburb", "war"),

    ("Gold hits record high", "economics"),
    ("Fed cuts rates by 25 basis points", "economics"),
    ("Stocks tumble in worst selloff since April", "economics"),
    ("Mortgage rate falls below 6%", "economics"),
    ("Bitcoin crashes", "economics"),
    ("Layoffs announced at major retailer", "economics"),
    ("Egg prices spike again", "economics"),
    ("Gas prices climb for the third week", "economics"),
    ("Housing market stalls as inventory builds", "economics"),
    ("Grocery bills up 12% year over year", "economics"),
    ("Amazon announces 14,000 job cuts", "economics"),
    ("Dollar slides to two-year low", "economics"),
    ("Social Security COLA announced", "economics"),
    ("Credit card debt hits record", "economics"),

    # Genuinely none of the three. Filing these anywhere is worse than dropping
    # them, and each one guards a term that would have been too greedy.
    ("Video: bear wanders into a grocery store", None),
    ("Taylor Swift announces stadium tour", None),
    ("Chiefs win in overtime thriller", None),
    ("Watch: cat rescued from storm drain", None),
    ("Man wins lottery twice in one week", None),
    ("New study links coffee to longer life", None),
    ("Photos: northern lights visible across the Midwest", None),
    ("Actor hospitalized after fall on set", None),
    ("World's oldest tortoise turns 191", None),
    ("Recipe: the only pie crust you need", None),
]

_MISFILED_LINKS = []
_UNSEEN = []
_GUESSED_AT_JUNK = []
for _title, _want in AGGREGATOR_CORPUS:
    _topic, _, _, _fallback = classify(_title, "", "politics", "politics", LEXICON)
    if _want is None:
        # The lexicon cannot tell junk from vocabulary it lacks, and must not
        # pretend otherwise: it should report that it saw nothing.
        if not _fallback:
            _GUESSED_AT_JUNK.append("%r scored as %s" % (_title, _topic))
    elif _fallback:
        _UNSEEN.append("%r should be %s and matched nothing" % (_title, _want))
    elif _topic != _want:
        _MISFILED_LINKS.append("%r → %s, wanted %s" % (_title, _topic, _want))

check("the lexicon has words for everything sortable", _UNSEEN, [])
check("the lexicon claims no signal in the junk", _GUESSED_AT_JUNK, [])
check("nothing sortable is misfiled", _MISFILED_LINKS, [])
check_true("the aggregator corpus is big enough to mean something",
           len(AGGREGATOR_CORPUS) >= 70)
check_true("and it is mostly sortable, which is the point",
           sum(1 for _, want in AGGREGATOR_CORPUS if want) >= 60)

# The lexicon never returns "nowhere", whatever the source is set to. This is the
# assertion that stops the disappearing act coming back: a word it does not know
# is not the same thing as a story that fits nowhere.
check("the lexicon always names a section",
      lexicon_topic("Recipe: the only pie crust you need"), "politics")
check("even on a source with a different default",
      lexicon_topic("Recipe: the only pie crust you need", prior="economics",
                    fallback="economics"), "economics")
check("and it admits it was guessing",
      saw_nothing("Recipe: the only pie crust you need"), True)


# --- The other sense of the word --------------------------------------------
#
# Every term added for the aggregator brought a second meaning with it, and these
# are the ones that actually appear on that kind of site. Each was a real misfile
# found by probing the expanded lexicon, and each fix is either a negative weight
# (the phrase cancels the term) or a weight below the threshold (the term needs
# company).

check("winning gold at the Olympics scores as nothing",
      saw_nothing("Man wins gold at the Olympics"), True)
check("a gold medal scores as nothing",
      saw_nothing("Team USA wins gold medal in Paris"), True)
check("but gold itself still scores",
      lexicon_topic("Gold hits record high"), "economics")

check("a war of words is not a war",
      lexicon_topic("War of words erupts between senators"), "politics")
check("a price war is not a war",
      saw_nothing("Price war breaks out among airlines"), True)
check("a bidding war is not a war",
      saw_nothing("Bidding war for the stadium site"), True)
check("a culture war is politics",
      lexicon_topic("Culture war fight over school library"), "politics")

check("a hike on a trail is not a rate hike",
      saw_nothing("Hikes on the Appalachian Trail get busier"), True)
check("a rate hike still is",
      lexicon_topic("Rate hikes are over, says Powell"), "economics")

check("a film bombing is not a war story",
      saw_nothing("Film bombs at the box office"), True)
check("bombing a place is", lexicon_topic("Israel bombs Gaza"), "war")

check("a union striking a deal is not a war story",
      saw_nothing("Union strikes deal with automaker"), True)
check("striking a place is", lexicon_topic("Israel strikes Gaza overnight"), "war")

# A university winning a championship was politics until the threshold stopped
# counting the source prior as evidence — the single biggest fix in this pass.
check("a university winning a championship scores as nothing",
      saw_nothing("University wins college football championship"), True)
check("a professor finding a beetle scores as nothing",
      saw_nothing("Professor discovers new species of beetle"), True)
check("waking up to snow scores as nothing",
      saw_nothing("Woke up to six inches of snow"), True)
check("an explosion in demand is not a war story",
      saw_nothing("Explosion in demand for used cars"), True)

# The prior may only break a tie between topics that both cleared on evidence.
check("the prior cannot get a story over the line",
      verdict_of("Woke up to six inches of snow", prior="politics")[3], True)
check("the prior still breaks a genuine tie",
      topic_of("Senators briefed on PPI data", prior="economics", fallback="economics"),
      "economics")
check("and the other way round",
      topic_of("Senators briefed on PPI data", prior="politics", fallback="politics"),
      "politics")

# Negative weights have to survive the parse and the word/phrase split.
_NEGATIVE = [term for term, weight in LEXICON["economics"] if weight < 0]
check_true("negative weights parse out of the Swift", len(_NEGATIVE) >= 3)


# --- Normalisation ----------------------------------------------------------

check("case is ignored", topic_of("AIRSTRIKE ON KYIV"), "war")

check("an apostrophe does not break a term",
      topic_of("Powell's testimony moves markets", prior="economics"), "economics")

check("punctuation between words does not break a phrase",
      topic_of("Report: air-strike hits depot"), "war")

check("normalisation collapses whitespace",
      normalise("  Air   strike\non   Kyiv  "), "air strike on kyiv")

check("normalisation keeps hyphens and ampersands",
      normalise("S&P 500 and the 10-year"), "s&p 500 and the 10-year")


# --- X bridge hosts ---------------------------------------------------------
#
# A self-hosted bridge is nearly always plain http on a port on the LAN, and
# defaulting those to https produces a TLS failure that reads exactly like the
# bridge being down. ATS permits cleartext to precisely these addresses via
# NSAllowsLocalNetworking, so the scheme guess and the ATS exception have to
# agree about what "local" means.

check("a LAN address is local", is_local_host("192.168.1.50:1200"), True)
check("a 10-net address is local", is_local_host("10.0.0.4:1200"), True)
check("loopback is local", is_local_host("127.0.0.1:1200"), True)
check("localhost is local", is_local_host("localhost:1200"), True)
check("an mDNS name is local", is_local_host("nas.local:1200"), True)

# 172.16.0.0/12 is 172.16 through 172.31 — not all of 172.
check("172.16 is local", is_local_host("172.16.0.9"), True)
check("172.31 is local", is_local_host("172.31.255.1"), True)
check("172.15 is not local", is_local_host("172.15.0.1"), False)
check("172.32 is not local", is_local_host("172.32.0.1"), False)

check("a public host is not local", is_local_host("rsshub.example.com"), False)
check("a public host that merely starts with 10 is not local",
      is_local_host("10minutemail.com"), False)

check("a LAN host defaults to http",
      normalized_host("192.168.1.50:1200"), "http://192.168.1.50:1200")

check("a public host defaults to https",
      normalized_host("rsshub.example.com"), "https://rsshub.example.com")

check("an explicit scheme is respected",
      normalized_host("http://rsshub.example.com"), "http://rsshub.example.com")

check("a trailing slash is dropped",
      normalized_host("https://nitter.example.com/"), "https://nitter.example.com")


# --- Following an aggregator's link -----------------------------------------
#
# A link aggregator's permalink is a stub: a headline, a "Go To Article" anchor,
# and share buttons. Opening it lands on the stub rather than the story, which
# is what the reader was doing. The anchor that matters has to be picked out of
# the ones that do not.

CFP_STUB = """
<h1>Watch Fauci invoke 5th amendment.</h1>
<p><a href="https://www.youtube.com/watch?v=abc123">Go To Article -- youtube.com</a></p>
<p><em>Posted by Kane on July 29, 2026 10:24 am</em></p>
<p><a href="https://citizenfreepress.com/">NEWS JUNKIES -- CHECK OUT OUR HOMEPAGE</a></p>
<div>Share:
  <a href="https://www.facebook.com/sharer.php?u=https://citizenfreepress.com/x/">Facebook</a>
  <a href="https://twitter.com/intent/tweet?url=https://citizenfreepress.com/x/">Twitter</a>
  <a href="mailto:?subject=Watch%20Fauci">Email</a>
</div>
<p><a href="https://citizenfreepress.com/">&lt; CITIZEN FREE PRESS -- HOMEPAGE</a></p>
"""

check("the outbound article wins over the homepage and the share buttons",
      outbound_link(CFP_STUB, "citizenfreepress.com"),
      "https://www.youtube.com/watch?v=abc123")

check("anchors are read with their text",
      links_in('<a href="/x">Go To Article -- youtube.com</a>')[0][1],
      "Go To Article -- youtube.com")

check("a same-host link is never the destination",
      outbound_link('<a href="https://citizenfreepress.com/other/">More</a>',
                    "citizenfreepress.com"),
      None)

check("www does not count as a different host",
      outbound_link('<a href="https://www.citizenfreepress.com/x/">More</a>',
                    "citizenfreepress.com"),
      None)

check("a facebook share link is not the destination",
      outbound_link('<a href="https://www.facebook.com/sharer.php?u=x">Share</a>',
                    "citizenfreepress.com"),
      None)

check("mailto is not the destination",
      outbound_link('<a href="mailto:someone@example.com">Email</a>', "citizenfreepress.com"),
      None)

# Position alone is not enough: aggregators put a site nav link above the story
# often enough that the label has to win when it is present.
check("the labelled link beats an earlier unlabelled one",
      outbound_link('<a href="https://ads.example.com/promo">Sponsored</a>'
                    '<a href="https://apnews.com/story">Go To Article -- apnews.com</a>',
                    "citizenfreepress.com"),
      "https://apnews.com/story")

check("an unlabelled offsite link is used when nothing is labelled",
      outbound_link('<a href="https://apnews.com/story">The story</a>', "citizenfreepress.com"),
      "https://apnews.com/story")

check("no links at all resolves to nothing",
      outbound_link("<p>Just text</p>", "citizenfreepress.com"), None)

# "<a" must not match "<article", or every semantic wrapper becomes a link.
check("an article tag is not mistaken for an anchor",
      len(links_in("<article><p>text</p></article>")), 0)

check("an unterminated anchor still yields its href",
      links_in('<a href="https://example.com/x">no closing tag')[0][0],
      "https://example.com/x")


# --- Steam announcement formatting ------------------------------------------
#
# Steam renders these placeholders and tags itself when it serves the store
# page; through the API they arrive raw. Left alone they are what "the
# formatting is broken" looks like — curly-braced paths where images should be
# and literal square brackets through the prose.

check("the clan image placeholder expands to the CDN",
      expand_placeholders("[img]{STEAM_CLAN_IMAGE}/12345/abc.png[/img]"),
      "[img]https://clan.cloudflare.steamstatic.com/images/12345/abc.png[/img]")

check("the localised placeholder expands too",
      expand_placeholders("{STEAM_CLAN_LOC_IMAGE}/x.png"),
      "https://clan.cloudflare.steamstatic.com/images/x.png")

check("an unmodelled tag with an attribute is removed",
      strip_remaining_tags("Watch [previewyoutube=abc123;full][/previewyoutube] now"),
      "Watch  now")

check("a quote with an author attribute is removed",
      strip_remaining_tags("[quote=devteam]We fixed it[/quote]"), "We fixed it")

# Patch notes are full of bracketed prose, and eating it would be worse than
# leaving a stray tag.
check("bracketed prose survives", strip_remaining_tags("[PC] Fixed a crash"), "[PC] Fixed a crash")
check("a capitalised label survives", strip_remaining_tags("[Fixed] the thing"), "[Fixed] the thing")
check("a bracketed number survives", strip_remaining_tags("issue [1234]"), "issue [1234]")
check("an unclosed bracket survives", strip_remaining_tags("a [ b"), "a [ b")


# --- Which alphabet an announcement is in -----------------------------------
#
# Steam's news API has no language parameter and no language field, so the text
# is the only thing to filter on. This does not identify a language and does not
# try to — it separates scripts a reader of English cannot read at all.

check("English is Latin", is_predominantly_latin("Update 1.4 is now live"), True)
check("accented Latin is Latin", is_predominantly_latin("Mise à jour disponible dès aujourd'hui"), True)
check("Chinese is not", is_predominantly_latin("更新公告：新版本现已推出，欢迎体验"), False)
check("Russian is not", is_predominantly_latin("Обновление уже доступно всем игрокам"), False)
check("Japanese is not", is_predominantly_latin("アップデートのお知らせ、新バージョン公開"), False)
check("Korean is not", is_predominantly_latin("업데이트 안내 새로운 버전이 출시되었습니다"), False)

# A version string has no letters to judge, and dropping it would be worse than
# showing it.
check("a version-only title is kept", is_predominantly_latin("v1.4.2"), True)
check("an empty title is kept", is_predominantly_latin(""), True)

# Bilingual announcements are common and stay, since half of it is readable.
check("a mixed title leaning Latin is kept",
      is_predominantly_latin("Update 1.4 is now live 更新"), True)


# --- The generated brief ----------------------------------------------------
#
# The Claude API request has three parts worth pinning without a network: the
# wire constants (read out of the Swift, so a typo in the endpoint or version
# header fails here instead of failing live), the input key that decides when a
# summary regenerates (and therefore when money is spent), and the prompt text.

_SUMMARY = summary_constants()

check("the endpoint is the Messages API",
      _SUMMARY.get("endpoint"), "https://api.anthropic.com/v1/messages")
check("the anthropic-version header is the stable one",
      _SUMMARY.get("apiVersion"), "2023-06-01")
check("the model is Haiku, the cheap one", _SUMMARY.get("model"), "claude-haiku-4-5")
check_true("the prompt revision is an integer", isinstance(_SUMMARY.get("promptRevision"), int))
check_true("max_tokens is a sane bound",
           isinstance(_SUMMARY.get("maxTokens"), int) and 0 < _SUMMARY["maxTokens"] <= 2000)

# The Swift must send the key in x-api-key and check for the refusal stop
# reason — both are the kind of detail that parses fine and fails live.
_SUMMARY_SOURCE = open(os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ios", "Dispatch", "Net", "SummaryAPI.swift"), encoding="utf-8").read()
check_true("the key goes in the x-api-key header", 'forHTTPHeaderField: "x-api-key"' in _SUMMARY_SOURCE)
check_true("the version header is sent", 'forHTTPHeaderField: "anthropic-version"' in _SUMMARY_SOURCE)
check_true("a refusal stop reason is handled", '"refusal"' in _SUMMARY_SOURCE)

# FNV-1a against the published test vectors, so the mirror and the Swift are
# both checked against a third thing rather than only against each other.
check("FNV-1a offset basis", stable_hash_hex(""), "cbf29ce484222325")
check("FNV-1a of 'a'", stable_hash_hex("a"), "af63dc4c8601ec8c")
check("FNV-1a of 'foobar'", stable_hash_hex("foobar"), "85944171f73967e8")

# The input key must not care about order — a refresh that reorders the same
# five headlines is not a change and must not bill.
_MODEL = _SUMMARY["model"]
_REVISION = _SUMMARY["promptRevision"]


def _key(ids, model=None, revision=None):
    return brief_input_key(ids,
                           model if model is not None else _MODEL,
                           revision if revision is not None else _REVISION)


check("the input key is order-independent",
      _key(["zerohedge:2", "twz:1", "cfp:3"]),
      _key(["cfp:3", "zerohedge:2", "twz:1"]))
check_true("a different set is a different key", _key(["a", "b"]) != _key(["a", "c"]))
check("the key is the hash of the model, revision and sorted ids",
      _key(["b", "a"]), stable_hash_hex("%s#%s\na\nb" % (_MODEL, _REVISION)))

# Changing either one has to invalidate the cache, or a model switch leaves the
# previous model's prose on screen until the news moves.
check_true("switching model changes the key",
           _key(["a"]) != _key(["a"], model="claude-opus-5"))
check_true("bumping the prompt revision changes the key",
           _key(["a"]) != _key(["a"], revision=_REVISION + 1))


# --- Bullets ----------------------------------------------------------------
#
# The prompt asks for one point per line and no bullet characters. These cases
# are what happens when a model ignores half of that.

check("plain lines become bullets",
      summary_bullets("Riyadh airport closes overnight\nUS tankers over the Gulf"),
      ["Riyadh airport closes overnight", "US tankers over the Gulf"])
check("dash markers are stripped",
      summary_bullets("- First thing\n- Second thing"), ["First thing", "Second thing"])
check("bullet glyphs are stripped",
      summary_bullets("• First thing\n· Second thing"), ["First thing", "Second thing"])
check("numbered markers are stripped",
      summary_bullets("1. First thing\n2) Second thing"), ["First thing", "Second thing"])
check("markdown bold is dropped", summary_bullets("**CPI** at 3.4%"), ["CPI at 3.4%"])
check("blank lines are dropped",
      summary_bullets("First thing\n\n\nSecond thing"), ["First thing", "Second thing"])
check("a stray marker line is dropped", summary_bullets("First thing\n-"), ["First thing"])

# The case that makes a naive marker-stripper wrong: a line that opens with a
# decimal. Eating "3." here would print "4% and rising".
check("a leading decimal survives",
      summary_bullets("3.4% and rising"), ["3.4% and rising"])
check("a leading year survives", summary_bullets("2026 deficit widens"), ["2026 deficit widens"])
check("a price survives", summary_bullets("1) 2.5% cut priced in"), ["2.5% cut priced in"])

# A model that returns one paragraph anyway still renders — as one bullet,
# which is worse-looking than four but not broken.
check("a paragraph is one bullet",
      summary_bullets("One long sentence about several things at once."),
      ["One long sentence about several things at once."])


# --- Keeping what a feed drops ----------------------------------------------
#
# A feed is a window, not an archive. Citizen Free Press publishes dozens of
# items a day and its RSS holds a fraction of them, so a refresh that replaced
# the list lost anything that entered and left between two fetches. These pin
# the merge that fixed it.

check("a first fetch is kept as-is",
      merge_articles([("a", 3), ("b", 2)], []), [("a", 3), ("b", 2)])

# The story that scrolled off the feed is still in the app.
check("items the feed dropped are retained",
      merge_articles([("c", 5), ("b", 4)], [("b", 4), ("a", 1)]),
      [("c", 5), ("b", 4), ("a", 1)])

# A re-fetch is where a corrected title or a resolved outbound link arrives, so
# the incoming copy has to win.
check("the incoming copy wins a collision",
      merge_articles([("a", 9)], [("a", 1)]), [("a", 9)])

check("the result is newest first",
      merge_articles([("new", 10)], [("old", 1), ("mid", 5)]),
      [("new", 10), ("mid", 5), ("old", 1)])
check("ties break on id, so ordering is stable",
      merge_articles([("b", 5)], [("a", 5)]), [("a", 5), ("b", 5)])
check("retention is bounded",
      merge_articles([("a", 3)], [("b", 2), ("c", 1)], retained=2), [("a", 3), ("b", 2)])

# The prompt, byte for byte.
check("the prompt shape",
      summary_prompt("Markets", [
          ("CPI comes in hot at 3.4%", "ZeroHedge", "23m"),
          ("Futures slide ahead of the open", "Citizen Free Press", None),
      ]),
      "Section: Markets\n"
      "Headlines, newest first:\n"
      "- [ZeroHedge, 23m] CPI comes in hot at 3.4%\n"
      "- [Citizen Free Press] Futures slide ahead of the open")


# --- The numbers behind a calendar release -----------------------------------
#
# Tapping a release shows the last published figures, from fredgraph.csv because
# it needs no key. Everything below is a real property of that file rather than a
# hypothetical: the header column has been renamed, gaps are a bare ".", and the
# line endings are CRLF.

_CSV = "observation_date,CPIAUCSL\r\n2026-05-01,320.500\r\n2026-06-01,321.400\r\n2026-07-01,322.100\r\n"

check("the CSV parses", fred_rows(_CSV),
      [("2026-05-01", 320.5), ("2026-06-01", 321.4), ("2026-07-01", 322.1)])

# The header is skipped by shape — its second field is not a number — so both
# spellings of the first column work and neither needs to be listed.
check("the modern header is skipped", len(fred_rows(_CSV)), 3)
check("the legacy DATE header is skipped",
      fred_rows("DATE,PAYEMS\n2026-07-01,159000\n"), [("2026-07-01", 159000.0)])

# A missing observation is a ".", which is neither a number nor an error. Parsing
# it as zero would print a crash in the economy that did not happen.
check("a missing observation is dropped",
      fred_rows("DATE,X\n2026-05-01,1.5\n2026-06-01,.\n"), [("2026-05-01", 1.5)])
check("a blank line is ignored", fred_rows("DATE,X\n\n2026-05-01,1.5\n"), [("2026-05-01", 1.5)])
check("a truncated line is ignored", fred_rows("DATE,X\n2026-05-01\n"), [])
check("a malformed date is ignored", fred_rows("DATE,X\nMay 2026,1.5\n"), [])

# Everything downstream reads newest-first.
check("observations come back newest first",
      [row[0] for row in fred_observations(_CSV)],
      ["2026-07-01", "2026-06-01", "2026-05-01"])

# Year-over-year is found by date, not by counting twelve rows back, so that the
# same code works for a weekly series and a monthly one.
_ROWS = [("2025-07-01", 312.0), ("2026-06-01", 321.4), ("2026-07-01", 322.1)]
check("the year-ago observation is found by date",
      nearest_observation(_ROWS, "2025-07-01"), ("2025-07-01", 312.0))
check("the nearest date wins when the exact one is missing",
      nearest_observation([("2025-06-15", 311.0), ("2025-08-20", 313.0)], "2025-07-01"),
      ("2025-06-15", 311.0))
check("an empty series has no year-ago point", nearest_observation([], "2025-07-01"), None)

check("year over year is a percentage",
      round(percent_change(322.1, 312.0), 2), 3.24)
check("a fall is negative", round(percent_change(98.0, 100.0), 2), -2.0)
# A zero denominator has to be inert rather than an infinity on the screen.
check("dividing by zero yields zero", percent_change(5.0, 0.0), 0.0)


# --- Filing with the model ---------------------------------------------------
#
# The lexicon knows five hundred terms and a wire uses words outside them all
# day, so Claude does the filing and the lexicon is the offline answer. Two pure
# pieces are worth pinning: the numbered prompt, and the parse of what comes
# back. A parse that silently drops a line is indistinguishable from a model that
# never answered, and both look like stories going missing — which is the bug
# this whole path exists to fix.

_CLASSIFIER = classifier_constants()
check_true("a batch is a sane size",
           isinstance(_CLASSIFIER.get("batchSize"), int) and 10 <= _CLASSIFIER["batchSize"] <= 100)
check_true("max_tokens leaves room for a whole batch",
           _CLASSIFIER["maxTokens"] >= _CLASSIFIER["batchSize"] * 6)

_CLASSIFIER_SOURCE = open(os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ios", "Dispatch", "Net", "ClassifierAPI.swift"), encoding="utf-8").read()
# It has to reuse the wire constants rather than writing its own copy.
check_true("the endpoint comes from SummaryAPI", "SummaryAPI.endpoint" in _CLASSIFIER_SOURCE)
check_true("so does the model", "SummaryAPI.model" in _CLASSIFIER_SOURCE)
check_true("a refusal is still handled", '"refusal"' in _CLASSIFIER_SOURCE)
# Every section name the prompt offers must be one the parser accepts, or an
# answer the model was told to give would be thrown away.
for _word in ("war", "politics", "economics", "gaming", "none"):
    check_true("the prompt offers %r" % _word, _word in _CLASSIFIER_SOURCE)

check("the prompt numbers from one",
      classifier_prompt(["Gold hits record high", "Israel strikes Gaza"]),
      "1. Gold hits record high\n2. Israel strikes Gaza")

# A headline containing a newline would break the numbering it is embedded in.
check("a multi-line headline is flattened",
      one_line("Breaking:\nexplosion reported"), "Breaking: explosion reported")
check("runs of whitespace collapse", one_line("a   b\t c"), "a b c")
check_true("a very long headline is bounded", len(one_line("x" * 500)) == 200)

# The reply parse. The format asked for is "3 politics"; models produce all of
# these, and each one used to be a story left unfiled.
check("the plain format parses", parse_decisions("1 war\n2 politics"), {1: "war", 2: "politics"})
check("a full stop after the number parses", parse_decisions("1. war"), {1: "war"})
check("a bracket parses", parse_decisions("2) economics"), {2: "economics"})
check("a dash parses", parse_decisions("3 - gaming"), {3: "gaming"})
check("an en dash parses", parse_decisions("4 \u2013 none"), {4: "none"})
check("a colon-free comma parses", parse_decisions("5, war"), {5: "war"})
check("capitals parse", parse_decisions("6 Politics"), {6: "politics"})
check("a two-digit number parses", parse_decisions("40 economics"), {40: "economics"})

# "none" has to survive as a word: it is the model saying "nowhere", which is a
# different thing from the model not answering, and only one of them hides a
# story.
check("none is a decision, not a missing answer", parse_decisions("7 none"), {7: "none"})

# Anything unreadable is left out rather than guessed at, so the lexicon's
# verdict stands for that story.
check("preamble is ignored",
      parse_decisions("Sure, here are the sections:\n1 war"), {1: "war"})
check("an unknown word is ignored", parse_decisions("1 sport"), {})
check("a line with no number is ignored", parse_decisions("war"), {})
check("a blank reply yields nothing", parse_decisions(""), {})
check("trailing prose is ignored",
      parse_decisions("1 war\nLet me know if you want these grouped differently."), {1: "war"})

# Realistic whole reply.
check("a whole batch parses",
      parse_decisions("1. politics\n2. war\n3. economics\n4. none\n5. politics"),
      {1: "politics", 2: "war", 3: "economics", 4: "none", 5: "politics"})


# --- Videos in an article ----------------------------------------------------
#
# An aggregator's post is often a video with a sentence under it, and the reader
# plays it in place rather than sending you to a consent dialog. All five link
# shapes below appear in real feeds; matching only the first is why an embedded
# player looks broken on half the posts that have one.

check("a watch link", youtube_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
check("a short link", youtube_id("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
check("an iframe embed", youtube_id("https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
check("a live link", youtube_id("https://www.youtube.com/live/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
check("a short-form link", youtube_id("https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
check("the no-cookie domain",
      youtube_id("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
check("a mobile link", youtube_id("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")

# Tracking parameters ride along on nearly every shared link.
check("trailing parameters are ignored",
      youtube_id("https://youtu.be/dQw4w9WgXcQ?t=42"), "dQw4w9WgXcQ")
check("a watch link with extra parameters",
      youtube_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share"), "dQw4w9WgXcQ")

# An id is eleven URL-safe characters. Anything else would build a player that
# loads nothing, which looks like the feature being broken.
check("a truncated id is refused", youtube_id("https://youtu.be/short"), None)
check("a channel page is not a video", youtube_id("https://www.youtube.com/@markets"), None)
check("another host is not YouTube",
      youtube_id("https://vimeo.com/dQw4w9WgXcQ"), None)
check("a bare string is not a link", youtube_id("dQw4w9WgXcQ"), None)


# --- A feed that answers with something else ---------------------------------
#
# The quietest failure this app has had. A host that answers a feed request with
# an anti-bot interstitial returns HTTP 200, so the fetch succeeds; the parse then
# finds no items, and returning that as a *result* meant the loader stopped
# without trying the backup addresses and without anything reaching the screen.
# The section was just empty. An RSS feed with zero items is broken, not quiet.

check("a challenge page is recognised",
      looks_like_html("<!DOCTYPE html><html><head><title>Just a moment...</title>"), True)
check("a plain html page is recognised", looks_like_html("<html><body>Blocked</body></html>"), True)
check("an RSS document is not html",
      looks_like_html('<?xml version="1.0"?><rss version="2.0"><channel>'), False)
check("an Atom document is not html",
      looks_like_html('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'), False)

# Only the head is inspected: an article body may legitimately contain the word.
check("html inside an article body is not a block",
      looks_like_html('<?xml version="1.0"?><rss><channel><item><description>'
                      + 'x' * 500 + '&lt;html&gt;</description></item></channel></rss>'), False)


# --- Report -----------------------------------------------------------------

if FAILURES:
    print("FAILED %d of %d checks\n" % (len(FAILURES), CHECKS))
    for failure in FAILURES:
        print("  - " + failure)
    sys.exit(1)

print("all %d feed parsing checks passed" % CHECKS)
