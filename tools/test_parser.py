#!/usr/bin/env python3
"""Assertions for the 4chan comment parser.

Run: python3 tools/test_parser.py

These fixtures are written against the HTML subset documented in
https://github.com/4chan/4chan-API and the markup 4chan's `com` field is known
to emit. They are hand-constructed, not scraped: this build environment's egress
policy blocks a.4cdn.org, so no live post bodies could be pulled. Anything here
that turns out to disagree with real markup should be corrected against a real
sample and the Swift port updated in step.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from comment_parser_reference import (  # noqa: E402
    parse, extract_quoted_posts, decode_entities,
    Span, ITALIC, BOLD, UNDERLINE, SPOILER, GREENTEXT, DEADLINK, SHIFT_JIS,
    link, quotelink, boardlink, is_quote_only_paragraph,
)

FAILURES = []
CHECKS = 0


def check(label, actual, expected):
    global CHECKS
    CHECKS += 1
    if actual != expected:
        FAILURES.append("%s\n     expected: %r\n     actual:   %r" % (label, expected, actual))


def paragraphs(html):
    return [b for b in parse(html) if b.kind == "paragraph"]


def only(html):
    ps = paragraphs(html)
    assert len(ps) == 1, "expected exactly one paragraph, got %d: %r" % (len(ps), ps)
    return ps[0]


# --- Entities ---------------------------------------------------------------

check("named entities decode",
      only("a &gt; b &amp; c &lt; d").text,
      "a > b & c < d")

check("decimal numeric entity decodes",
      only("it&#039;s fine").text,
      "it's fine")

check("hex numeric entity decodes",
      only("it&#x27;s fine").text,
      "it's fine")

check("em dash entity decodes",
      only("one &mdash; two").text,
      "one — two")

check("bare ampersand survives without eating the line",
      only("Q &amp A, then more text follows here").text,
      "Q &amp A, then more text follows here")

# 4chan always emits the terminating semicolon. Decoding "&amp" without one
# (as HTML5 permits in some positions) would make a bare "&" ahead of a word
# lossy, so the parser requires the semicolon and leaves the rest literal.
check("entity without a semicolon stays literal",
      only("100 &amp 200 &notanentity").text,
      "100 &amp 200 &notanentity")

check("decode_entities handles hrefs",
      decode_entities("https://e.com/a?x=1&amp;y=2&#38;z=3"),
      "https://e.com/a?x=1&y=2&z=3")


# --- Stray angle brackets (the bug the handoff says shipped) -----------------

check("stray '<' in prose is not a tag",
      only("a &lt; b and c &gt; d").text,
      "a < b and c > d")

check("raw '<' followed by space stays literal",
      only("if x < 3 then stop").text,
      "if x < 3 then stop")

check("raw '<' followed by digit stays literal",
      only("x <3 y").text,
      "x <3 y")

check("unterminated tag is literal text",
      only("compare a <b and move on").text,
      "compare a <b and move on")


# --- Emphasis offsets -------------------------------------------------------

p = only("plain <i>word</i> after")
check("italic text", p.text, "plain word after")
check("italic span covers exactly the word", p.spans, [Span(6, 4, ITALIC)])

p = only("<b>bold</b> and <em>em</em>")
check("bold+em text", p.text, "bold and em")
check("bold+em spans", p.spans, [Span(0, 4, BOLD), Span(9, 2, ITALIC)])

p = only("<u>under</u>")
check("underline span", p.spans, [Span(0, 5, UNDERLINE)])

p = only("outer <b>bold <i>both</i></b> end")
check("nested text", p.text, "outer bold both end")
check("nested spans overlap correctly",
      sorted([(s.start, s.length, s.style) for s in p.spans]),
      [(6, 9, BOLD), (11, 4, ITALIC)])


# --- Spoilers ---------------------------------------------------------------

p = only("before <s>hidden</s> after")
check("spoiler text is kept", p.text, "before hidden after")
check("spoiler span covers the hidden run", p.spans, [Span(7, 6, SPOILER)])


# --- Greentext --------------------------------------------------------------

p = only('<span class="quote">&gt;implying anything</span>')
check("greentext keeps its leading angle bracket", p.text, ">implying anything")
check("greentext span covers the line", p.spans, [Span(0, 18, GREENTEXT)])


# --- Quotelinks -------------------------------------------------------------

p = only('<a href="#p123456789" class="quotelink">&gt;&gt;123456789</a>')
check("same-thread quotelink text", p.text, ">>123456789")
check("same-thread quotelink span",
      p.spans, [Span(0, 11, quotelink(None, None, 123456789))])

p = only('<a href="/pol/thread/111#p222" class="quotelink">&gt;&gt;222</a>')
check("cross-thread quotelink span",
      p.spans, [Span(0, 5, quotelink("pol", 111, 222))])

p = only('<a href="//boards.4chan.org/g/thread/900#p901" class="quotelink">&gt;&gt;&gt;/g/901</a>')
check("cross-board quotelink span",
      p.spans, [Span(0, 9, quotelink("g", 900, 901))])

p = only('<a href="//boards.4chan.org/g/" class="quotelink">&gt;&gt;&gt;/g/</a>')
check("board link span", p.spans, [Span(0, 6, boardlink("g"))])

p = only('<span class="deadlink">&gt;&gt;999</span>')
check("deadlink text", p.text, ">>999")
check("deadlink span", p.spans, [Span(0, 5, DEADLINK)])

check("greentext wrapping a quotelink keeps both",
      sorted([(s.start, s.length, s.style[0]) for s in only(
          '<span class="quote">&gt;<a href="#p5" class="quotelink">&gt;&gt;5</a> no</span>'
      ).spans]),
      [(0, 7, "greentext"), (1, 3, "quotelink")])


# --- External links ---------------------------------------------------------

p = only('see <a href="https://example.com/a?x=1&amp;y=2" rel="nofollow">this</a> now')
check("external link text", p.text, "see this now")
check("external link range and decoded url",
      p.spans, [Span(4, 4, link("https://example.com/a?x=1&y=2"))])

p = only('<a href="javascript:alert(1)">click</a> me')
check("javascript href keeps text", p.text, "click me")
check("javascript href produces no link", p.spans, [])

p = only('<a href="mailto:a@b.c">mail</a>')
check("mailto produces no link", p.spans, [])

p = only('<a href="HTTPS://Example.com/x">up</a>')
check("uppercase scheme is accepted", p.spans, [Span(0, 2, link("HTTPS://Example.com/x"))])


# --- <wbr> ------------------------------------------------------------------

p = only('<a href="https://example.com/verylongpath" rel="nofollow">https://example.com/very<wbr>longpath</a>')
check("wbr inserts nothing into the anchor text",
      p.text, "https://example.com/verylongpath")
check("wbr does not split the link span",
      p.spans, [Span(0, 32, link("https://example.com/verylongpath"))])

check("wbr in prose vanishes", only("Anti<wbr>disestablishment").text, "Antidisestablishment")


# --- Line breaks ------------------------------------------------------------

ps = paragraphs("first<br>second<br>third")
check("br splits paragraphs", [x.text for x in ps], ["first", "second", "third"])

ps = paragraphs("a<br><br>b")
check("blank paragraph between double br is dropped", [x.text for x in ps], ["a", "b"])

ps = paragraphs("<br>   <br>only<br>  <br>")
check("leading and trailing blank paragraphs are dropped",
      [x.text for x in ps], ["only"])

ps = paragraphs("<b>bold start<br>bold end</b>")
check("emphasis across br splits into two paragraphs",
      [x.text for x in ps], ["bold start", "bold end"])
check("emphasis reopens on the next line",
      [x.spans for x in ps], [[Span(0, 10, BOLD)], [Span(0, 8, BOLD)]])


# --- Whitespace trimming shifts spans ---------------------------------------

p = only("   <i>word</i> trailing   ")
check("trimmed paragraph text", p.text, "word trailing")
check("span offsets shift with the trim", p.spans, [Span(0, 4, ITALIC)])

p = only("&nbsp;&nbsp;<b>x</b>")
check("nbsp-only lead is trimmed", p.text, "x")
check("span survives nbsp trim", p.spans, [Span(0, 1, BOLD)])


# --- Code blocks ------------------------------------------------------------

blocks = parse('text<br><pre class="prettyprint">if (a &lt; b) {<br>  go();<br>}</pre>tail')
check("code block splits the surrounding text",
      [b.kind for b in blocks], ["paragraph", "code", "paragraph"])
check("code block decodes its entities and keeps newlines",
      blocks[1].text, "if (a < b) {\n  go();\n}")
check("text after code block survives", blocks[2].text, "tail")

blocks = parse('<pre class="prettyprint">   </pre>')
check("whitespace-only code block is dropped", blocks, [])

p = only("use <code>malloc()</code> here")
check("inline code text", p.text, "use malloc() here")
check("inline code span", p.spans, [Span(4, 8, ("code",))])


# --- Shift-JIS --------------------------------------------------------------

p = only('<span class="sjis">( ﾟ Д ﾟ)</span>')
check("sjis span is tagged for monospace", p.spans, [Span(0, 8, SHIFT_JIS)])


# --- Empty and degenerate input ---------------------------------------------

check("empty comment yields no blocks", parse(""), [])
check("None comment yields no blocks", parse(None), [])
check("markup-only comment yields no blocks", parse("<br><br>"), [])
check("unknown tag is dropped but its text kept",
      only("<marquee>hello</marquee>").text, "hello")


# --- Backlink extraction ----------------------------------------------------

check("quoted posts are extracted in order without duplicates",
      extract_quoted_posts(
          '<a href="#p100" class="quotelink">&gt;&gt;100</a> '
          '<a href="#p200" class="quotelink">&gt;&gt;200</a><br>'
          '<a href="#p100" class="quotelink">&gt;&gt;100</a> again'
      ),
      [100, 200])

check("cross-board quotes are not counted as same-thread replies",
      extract_quoted_posts(
          '<a href="#p10" class="quotelink">&gt;&gt;10</a> '
          '<a href="//boards.4chan.org/g/thread/1#p2" class="quotelink">&gt;&gt;&gt;/g/2</a>'
      ),
      [10])

check("a >>123 inside a code block is not a reply",
      extract_quoted_posts('<pre class="prettyprint">&gt;&gt;123</pre>'),
      [])

check("a dropped link containing digits is not a reply",
      extract_quoted_posts('<a href="javascript:x">&gt;&gt;123</a>'),
      [])


# --- Realistic composite ----------------------------------------------------

sample = (
    '<a href="#p487110000" class="quotelink">&gt;&gt;487110000</a><br>'
    '<span class="quote">&gt;he thinks the numbers are real</span><br>'
    'Source: <a href="https://example.org/report?id=1&amp;p=2" rel="nofollow">'
    'example.org/report<wbr>?id=1</a><br>'
    '<br>'
    'Read it <s>before replying</s>.'
)
blocks = parse(sample)
check("composite paragraph count", len(blocks), 4)
check("composite line 1", blocks[0].text, ">>487110000")
check("composite line 1 span", blocks[0].spans, [Span(0, 11, quotelink(None, None, 487110000))])
check("composite line 2", blocks[1].text, ">he thinks the numbers are real")
check("composite line 2 is greentext", blocks[1].spans, [Span(0, 31, GREENTEXT)])
check("composite line 3", blocks[2].text, "Source: example.org/report?id=1")
check("composite line 3 link", blocks[2].spans,
      [Span(8, 23, link("https://example.org/report?id=1&p=2"))])
check("composite line 4", blocks[3].text, "Read it before replying.")
check("composite line 4 spoiler", blocks[3].spans, [Span(8, 15, SPOILER)])
check("composite quoted posts", extract_quoted_posts(sample), [487110000])


# --- Redundant parent quotes (threaded view) ---------------------------------
#
# Once a reply is drawn underneath the post it answers, the ">>123" line that
# addressed it is noise. It is only dropped when the paragraph is nothing but
# quotelinks at an ancestor.

def quote_only(html, targets):
    ps = paragraphs(html)
    return [is_quote_only_paragraph(p, set(targets)) for p in ps]


check("a lone parent quote is droppable",
      quote_only('<a href="#p10" class="quotelink">&gt;&gt;10</a>', [10]),
      [True])

check("two stacked parent quotes are droppable",
      quote_only(
          '<a href="#p10" class="quotelink">&gt;&gt;10</a> '
          '<a href="#p11" class="quotelink">&gt;&gt;11</a>', [10, 11]),
      [True])

check("a quote followed by real text is kept",
      quote_only('<a href="#p10" class="quotelink">&gt;&gt;10</a> you are wrong', [10]),
      [False])

check("a quote at a non-ancestor is kept",
      quote_only('<a href="#p99" class="quotelink">&gt;&gt;99</a>', [10]),
      [False])

# Dropping this line would silently lose the fact that the post also answers
# 99, which the nesting cannot show — it can only sit under one parent.
check("a line naming an ancestor and a stranger is kept",
      quote_only(
          '<a href="#p10" class="quotelink">&gt;&gt;10</a> '
          '<a href="#p99" class="quotelink">&gt;&gt;99</a>', [10]),
      [False])

check("a cross-thread quote on the line keeps it",
      quote_only(
          '<a href="#p10" class="quotelink">&gt;&gt;10</a> '
          '<a href="/pol/thread/5#p6" class="quotelink">&gt;&gt;6</a>', [10]),
      [False])

check("greentext is never droppable",
      quote_only('<span class="quote">&gt;you</span>', [10]),
      [False])

check("only the leading quote line is droppable, not the body",
      quote_only(
          '<a href="#p10" class="quotelink">&gt;&gt;10</a><br>actual argument here', [10]),
      [True, False])

check("a deadlink to the parent is not a quotelink and is kept",
      quote_only('<span class="deadlink">&gt;&gt;10</span>', [10]),
      [False])


# --- Report -----------------------------------------------------------------

if FAILURES:
    print("FAILED %d of %d checks\n" % (len(FAILURES), CHECKS))
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)

print("all %d parser checks passed" % CHECKS)
