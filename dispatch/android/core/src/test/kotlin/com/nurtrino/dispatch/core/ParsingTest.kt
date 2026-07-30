package com.nurtrino.dispatch.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android port of the assertions in `tools/test_feeds.py`.
 *
 * These run on the JVM, which means they run in the development environment
 * rather than only on CI — the difference between a two-second check and a
 * seven-minute round trip. Every case is one where the naive implementation
 * returns nothing or something subtly wrong, and a feed reader with a broken
 * parser does not crash: it shows an empty section.
 */
class XmlRepairTest {

    @Test
    fun `a bare ampersand is escaped`() =
        assertEquals("Q&amp;A with the Fed", XmlSanitizer.rewriteEntities("Q&A with the Fed"))

    @Test
    fun `nbsp becomes a numeric reference`() =
        assertEquals("hard&#160;space", XmlSanitizer.rewriteEntities("hard&nbsp;space"))

    @Test
    fun `XML's own five are left alone`() =
        assertEquals(
            "&amp;&lt;&gt;&quot;&apos;",
            XmlSanitizer.rewriteEntities("&amp;&lt;&gt;&quot;&apos;"),
        )

    @Test
    fun `a valid numeric reference is left alone`() =
        assertEquals("&#8212; and &#x2014;", XmlSanitizer.rewriteEntities("&#8212; and &#x2014;"))

    @Test
    fun `an unknown entity keeps its text but loses its ampersand`() =
        assertEquals("&amp;nosuchthing;", XmlSanitizer.rewriteEntities("&nosuchthing;"))

    @Test
    fun `an ampersand in a query string is escaped`() =
        assertEquals(
            "<link>http://x.com/?a=1&amp;b=2</link>",
            XmlSanitizer.rewriteEntities("<link>http://x.com/?a=1&b=2</link>"),
        )

    /** Without a length cap this swallows twenty characters as an entity name. */
    @Test
    fun `a distant semicolon does not make an entity`() =
        assertEquals(
            "Smith &amp; Wesson; the company",
            XmlSanitizer.rewriteEntities("Smith & Wesson; the company"),
        )

    @Test
    fun `a control character is dropped outright`() =
        assertEquals("beforeafter", XmlSanitizer.rewriteEntities("beforeafter"))

    @Test
    fun `tab newline and carriage return survive`() =
        assertEquals("a\tb\nc\rd", XmlSanitizer.rewriteEntities("a\tb\nc\rd"))

    @Test
    fun `a reference to a forbidden character is dropped`() =
        assertEquals("xy", XmlSanitizer.rewriteEntities("x&#12;y"))

    @Test
    fun `the declared encoding is rewritten to UTF-8`() =
        assertEquals(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss/>",
            XmlSanitizer.sanitize("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><rss/>"),
        )

    @Test
    fun `a leading BOM is stripped`() =
        assertEquals(
            "<?xml version=\"1.0\"?><rss/>",
            XmlSanitizer.sanitize("﻿<?xml version=\"1.0\"?><rss/>"),
        )
}

class FeedParserTest {

    /** A feed carrying everything wrong with it that a real one has. */
    private val dirtyRss = """<?xml version="1.0" encoding="ISO-8859-1"?>
<rss version="2.0">
<channel>
<title>ZeroHedge</title>
<link>https://www.zerohedge.com</link>
<item>
  <title>Fed Holds Rates, Q&amp;A Turns Testy</title>
  <link>https://www.zerohedge.com/markets/fed-holds?utm_source=feed&amp;utm_medium=rss</link>
  <guid isPermaLink="false">node/12345</guid>
  <description>Powell&nbsp;said the committee&rsquo;s view had not changed &mdash; much.</description>
  <pubDate>Tue, 28 Jul 2026 18:30:00 GMT</pubDate>
</item>
</channel>
</rss>"""

    @Test
    fun `a dirty RSS feed still yields an item`() {
        val feed = FeedParser.parse(dirtyRss.toByteArray())
        assertEquals(1, feed.items.size)
        assertEquals("https://www.zerohedge.com", feed.siteLink)
    }

    @Test
    fun `entities round-trip to real characters`() {
        val item = FeedParser.parse(dirtyRss.toByteArray()).items.first()
        val article = item.toArticle("zerohedge", null, null)
        assertEquals("Fed Holds Rates, Q&A Turns Testy", article.title)
        assertTrue(article.summary.contains("committee’s"))
        assertTrue(article.summary.contains("—"))
    }

    @Test
    fun `the date parses`() {
        val item = FeedParser.parse(dirtyRss.toByteArray()).items.first()
        assertNotNull(item.published)
    }

    /** Atom puts the address in an attribute, and its self link is not the site. */
    @Test
    fun `an Atom entry parses`() {
        val atom = """<?xml version="1.0" encoding="utf-8"?>
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
  </entry>
</feed>"""
        val feed = FeedParser.parse(atom.toByteArray())
        assertEquals(1, feed.items.size)
        assertEquals("https://www.twz.com", feed.siteLink)
        assertEquals("https://www.twz.com/sea/carrier", feed.items.first().link)
    }

    /** The id must survive a re-fetch, or read state resets on every refresh. */
    @Test
    fun `the id is stable across parses`() {
        val first = FeedParser.parse(dirtyRss.toByteArray()).items.first()
            .toArticle("zerohedge", null, null).id
        val second = FeedParser.parse(dirtyRss.toByteArray()).items.first()
            .toArticle("zerohedge", null, null).id
        assertEquals(first, second)
    }
}

class HtmlTextTest {

    @Test
    fun `tags are stripped and entities decoded`() =
        assertEquals(
            "Powell’s “pause”",
            HtmlText.plainText("<p>Powell&rsquo;s &ldquo;pause&rdquo;</p>"),
        )

    @Test
    fun `a script block goes with its contents`() =
        assertEquals(
            "Real text\nMore",
            HtmlText.plainText("<p>Real text</p><script>var x = 1 < 2;</script><p>More</p>"),
        )

    /** Removing `script` by prefix match also removes `section`. */
    @Test
    fun `a section survives`() =
        assertTrue(HtmlText.plainText("<section><p>Body</p></section>").contains("Body"))

    /** Source newlines are insignificant whitespace, not line breaks. */
    @Test
    fun `a wrapped sentence stays one line`() =
        assertEquals(
            "The Federal Reserve said today that rates would hold.",
            HtmlText.plainText("<p>The Federal Reserve said today\nthat rates would hold.</p>"),
        )

    @Test
    fun `data-src wins over a placeholder src`() =
        assertEquals(
            "https://cdn.example.com/real.jpg",
            HtmlText.firstImageUrl(
                """<img src="https://cdn.example.com/placeholder.gif" """ +
                    """data-src="https://cdn.example.com/real.jpg">""",
            ),
        )

    @Test
    fun `a data uri is not an image`() =
        assertEquals(null, HtmlText.firstImageUrl("""<img src="data:image/gif;base64,R0lG">"""))

    @Test
    fun `an outbound link is found past the aggregator's own host`() =
        assertEquals(
            "https://www.reuters.com/world/story",
            HtmlText.outboundLink(
                """<a href="https://citizenfreepress.com/tag/x">tag</a>""" +
                    """<a href="https://www.reuters.com/world/story">Go To Article</a>""",
                "citizenfreepress.com",
            ),
        )

    @Test
    fun `a share link is not the article`() =
        assertEquals(
            null,
            HtmlText.outboundLink(
                """<a href="https://twitter.com/intent/tweet">Tweet</a>""",
                "citizenfreepress.com",
            ),
        )
}

class UrlCanonicalTest {

    @Test
    fun `tracking parameters are not identity`() =
        assertEquals(
            UrlCanonical.key("https://www.zerohedge.com/markets/fed"),
            UrlCanonical.key("https://zerohedge.com/markets/fed?utm_source=feed&utm_medium=rss"),
        )

    @Test
    fun `a trailing slash is formatting`() =
        assertEquals(UrlCanonical.key("https://x.com/a/b"), UrlCanonical.key("https://x.com/a/b/"))

    @Test
    fun `a real parameter is kept`() =
        assertTrue(UrlCanonical.key("https://x.com/a?id=7")!!.contains("id=7"))

    @Test
    fun `two different pages do not collide`() =
        assertTrue(UrlCanonical.key("https://x.com/a") != UrlCanonical.key("https://x.com/b"))
}

class HeadlineTest {

    @Test
    fun `a short body is its own headline`() =
        assertEquals(
            "Explosion reported in Riyadh",
            Article.headline("Explosion reported in Riyadh"),
        )

    @Test
    fun `a long body is cut at a sentence`() =
        assertEquals(
            "Missiles were intercepted overnight.",
            Article.headline("Missiles were intercepted overnight. " + "More detail ".repeat(20)),
        )

    @Test
    fun `an empty body is not blank`() = assertEquals("Untitled", Article.headline("  "))
}
