package com.nurtrino.dispatch.core

import java.io.ByteArrayInputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import org.w3c.dom.Node

class ParsedFeed(val siteLink: String?, val items: List<FeedItem>)

class FeedItem(
    val title: String,
    val link: String?,
    val guid: String?,
    val summaryHtml: String,
    val bodyHtml: String?,
    val author: String?,
    val published: Long?,
    val imageUrl: String?,
) {
    /**
     * The identity is derived before any link rewriting, so following an
     * aggregator's permalink to its destination cannot change an article's id and
     * reset its read state.
     */
    fun toArticle(sourceId: String, siteLink: String?, context: String?): Article {
        val identity = guid ?: link ?: StableHash.hex(title + summaryHtml)
        val body = bodyHtml ?: summaryHtml
        return Article(
            id = "$sourceId|${StableHash.hex(identity)}",
            sourceId = sourceId,
            title = HtmlText.decodeEntities(title).trim(),
            summary = HtmlText.plainText(summaryHtml),
            bodyHtml = body.ifEmpty { null },
            link = absolute(link, siteLink),
            imageUrl = imageUrl?.let { absolute(it, siteLink) },
            author = author,
            published = published,
            context = context,
        )
    }

    private fun absolute(url: String?, base: String?): String? {
        if (url == null) return null
        if (url.startsWith("http")) return url
        if (base == null) return null
        return base.trimEnd('/') + "/" + url.trimStart('/')
    }
}

/**
 * RSS 2.0, Atom and RSS 1.0/RDF through one parser.
 *
 * A DOM parse rather than a pull parse: the documents are small, and the three
 * formats disagree about where everything lives, which reads far better as
 * "look for any of these element names" than as a state machine.
 */
object FeedParser {

    fun parse(bytes: ByteArray): ParsedFeed {
        val repaired = XmlSanitizer.sanitize(String(bytes, Charsets.UTF_8))

        val factory = DocumentBuilderFactory.newInstance()
        // Namespace-unaware on purpose: feeds declare prefixes inconsistently
        // (`content:encoded`, `dc:creator`) and matching on the literal tag name
        // is what makes one code path work for all three formats.
        factory.isNamespaceAware = false
        // A feed is untrusted input from the network. Both of these stop a
        // malicious or broken document reading local files or expanding into
        // gigabytes of entities.
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        factory.isExpandEntityReferences = false

        val document = factory.newDocumentBuilder()
            .parse(ByteArrayInputStream(repaired.toByteArray(Charsets.UTF_8)))
        val root = document.documentElement

        val siteLink = channelLink(root)
        val items = ArrayList<FeedItem>()
        for (name in listOf("item", "entry")) {
            val nodes = root.getElementsByTagName(name)
            for (index in 0 until nodes.length) {
                (nodes.item(index) as? Element)?.let { items.add(parseItem(it)) }
            }
        }
        return ParsedFeed(siteLink, items)
    }

    private fun channelLink(root: Element): String? {
        val channel = firstChild(root, "channel") ?: root
        for (index in 0 until channel.childNodes.length) {
            val node = channel.childNodes.item(index) as? Element ?: continue
            if (node.tagName != "link") continue
            // Atom puts the address in an attribute and RSS in the text. An Atom
            // feed also has a `rel="self"` link, which is the feed, not the site.
            val rel = node.getAttribute("rel")
            if (rel == "self") continue
            val href = node.getAttribute("href")
            if (href.isNotEmpty()) return href
            val text = node.textContent?.trim()
            if (!text.isNullOrEmpty()) return text
        }
        return null
    }

    private fun parseItem(element: Element): FeedItem {
        val body = text(element, "content:encoded")
            ?: text(element, "content")
            ?: text(element, "description")
            ?: ""
        val summary = text(element, "description")
            ?: text(element, "summary")
            ?: body

        return FeedItem(
            title = text(element, "title") ?: "",
            link = itemLink(element),
            guid = text(element, "guid") ?: text(element, "id"),
            summaryHtml = summary,
            bodyHtml = body.ifEmpty { null },
            author = text(element, "dc:creator") ?: text(element, "author") ?: authorName(element),
            published = DateParsing.parse(
                text(element, "pubDate")
                    ?: text(element, "published")
                    ?: text(element, "updated")
                    ?: text(element, "dc:date")
            ),
            imageUrl = mediaImage(element) ?: HtmlText.firstImageUrl(body),
        )
    }

    private fun itemLink(element: Element): String? {
        val nodes = element.getElementsByTagName("link")
        var fallback: String? = null
        for (index in 0 until nodes.length) {
            val node = nodes.item(index) as? Element ?: continue
            val rel = node.getAttribute("rel")
            if (rel.isNotEmpty() && rel != "alternate") continue
            val href = node.getAttribute("href")
            if (href.isNotEmpty()) return href
            val text = node.textContent?.trim()
            if (!text.isNullOrEmpty() && fallback == null) fallback = text
        }
        return fallback
    }

    private fun authorName(element: Element): String? =
        firstChild(element, "author")?.let { text(it, "name") }

    private fun mediaImage(element: Element): String? {
        for (name in listOf("media:content", "media:thumbnail", "enclosure")) {
            val nodes = element.getElementsByTagName(name)
            for (index in 0 until nodes.length) {
                val node = nodes.item(index) as? Element ?: continue
                val type = node.getAttribute("type")
                if (type.isNotEmpty() && !type.startsWith("image")) continue
                val url = node.getAttribute("url")
                if (url.isNotEmpty()) return url
            }
        }
        return null
    }

    private fun firstChild(element: Element, name: String): Element? {
        for (index in 0 until element.childNodes.length) {
            val node = element.childNodes.item(index)
            if (node.nodeType == Node.ELEMENT_NODE && (node as Element).tagName == name) return node
        }
        return null
    }

    private fun text(element: Element, name: String): String? {
        val child = firstChild(element, name) ?: return null
        return child.textContent?.takeIf { it.isNotBlank() }
    }
}
