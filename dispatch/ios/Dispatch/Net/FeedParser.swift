import Foundation

/// One item as the feed wrote it, before it becomes an `Article`.
struct ParsedItem {
    var title: String?
    var link: String?
    var guid: String?
    var summaryHTML: String?
    var contentHTML: String?
    var dateRaw: String?
    var author: String?
    var mediaURL: String?

    /// The richest body available. `content:encoded` when the publisher sends
    /// the whole article — ZeroHedge's full feed does — and the description
    /// otherwise.
    var bodyHTML: String? {
        let content = contentHTML?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summaryHTML?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let content, !content.isEmpty,
           content.count >= (summary?.count ?? 0) {
            return content
        }
        if let summary, !summary.isEmpty { return summary }
        return content
    }
}

struct ParsedFeed {
    var title: String?
    var siteLink: String?
    var items: [ParsedItem] = []
}

/// RSS 2.0, Atom and RSS 1.0/RDF, through one parser.
///
/// They differ in element names far more than in structure, so rather than
/// sniffing the format up front and branching, this reads whichever of the
/// known element names it meets. A `<description>` and a `<summary>` land in
/// the same field; an item is an `<item>` or an `<entry>`. That also means a
/// hybrid feed — and there are plenty, Atom elements sprinkled through an RSS
/// 2.0 document — parses without special handling.
enum FeedParser {

    static func parse(_ data: Data) throws -> ParsedFeed {
        let sanitized = XMLSanitizer.sanitizedData(from: data)
        let parser = XMLParser(data: sanitized)
        // Off, so element names arrive qualified: matching "content:encoded"
        // directly is simpler than resolving namespace URIs, and feeds are
        // inconsistent about declaring them properly anyway.
        parser.shouldProcessNamespaces = false

        let delegate = FeedXMLDelegate()
        parser.delegate = delegate

        let ok = parser.parse()

        // A partial parse still counts. A feed that breaks two thirds of the
        // way down should show the two thirds that arrived, not nothing —
        // XMLParser stops at the error but keeps everything before it.
        if !ok && delegate.feed.items.isEmpty {
            throw FeedError.notAFeed
        }
        guard !delegate.feed.items.isEmpty else { throw FeedError.empty }
        return delegate.feed
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {

    var feed = ParsedFeed()

    private var stack: [String] = []
    private var buffer = ""
    private var current: ParsedItem?

    private static let itemElements: Set<String> = ["item", "entry"]

    private static let contentElements: Set<String> = [
        "content:encoded", "content", "media:description", "summary", "description",
    ]

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        let name = elementName.lowercased()
        stack.append(name)
        buffer = ""

        if FeedXMLDelegate.itemElements.contains(name) {
            current = ParsedItem()
            return
        }

        guard current != nil else { return }

        switch name {
        case "link":
            // Atom carries the URL in an attribute; RSS puts it in the text,
            // which `didEndElement` picks up instead.
            guard let href = attributes["href"], !href.isEmpty else { break }
            let rel = attributes["rel"]?.lowercased() ?? "alternate"
            switch rel {
            case "alternate":
                if current?.link == nil { current?.link = href }
            case "enclosure":
                if isImage(url: href, type: attributes["type"]) { setMedia(href) }
            default:
                break
            }

        case "enclosure":
            guard let url = attributes["url"], !url.isEmpty else { break }
            if isImage(url: url, type: attributes["type"]) { setMedia(url) }

        case "media:content", "media:thumbnail", "media:group":
            guard let url = attributes["url"], !url.isEmpty else { break }
            let medium = attributes["medium"]?.lowercased()
            if medium == "image" || medium == nil || isImage(url: url, type: attributes["type"]) {
                setMedia(url)
            }

        case "itunes:image":
            if let href = attributes["href"], !href.isEmpty { setMedia(href) }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        buffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let name = elementName.lowercased()
        if !stack.isEmpty { stack.removeLast() }

        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""

        if FeedXMLDelegate.itemElements.contains(name) {
            if let item = current, isUsable(item) { feed.items.append(item) }
            current = nil
            return
        }

        guard current != nil else {
            handleChannelElement(name, value: value)
            return
        }
        guard !value.isEmpty else { return }

        switch name {
        case "title", "media:title":
            if current?.title?.isEmpty ?? true { current?.title = value }
        case "link":
            if current?.link == nil { current?.link = value }
        case "guid", "id":
            if current?.guid == nil { current?.guid = value }
        case "description", "summary", "subtitle":
            if current?.summaryHTML == nil { current?.summaryHTML = value }
        case "content:encoded", "content", "content:html":
            if (current?.contentHTML?.count ?? 0) < value.count { current?.contentHTML = value }
        case "pubdate", "published", "dc:date", "dcterms:created", "created":
            if current?.dateRaw == nil { current?.dateRaw = value }
        case "updated", "lastbuilddate", "dcterms:modified", "atom:updated":
            // Only as a last resort: an "updated" stamp on an old article
            // republishes it to the top of the feed on every edit.
            if current?.dateRaw == nil { current?.dateRaw = value }
        case "author", "dc:creator", "creator", "name":
            if current?.author == nil { current?.author = cleanAuthor(value) }
        case "media:thumbnail", "image", "url":
            // RSS 1.0 and a few WordPress plugins nest `<url>` inside an
            // image element rather than using an attribute.
            if stack.contains(where: { $0.contains("image") || $0.contains("thumbnail") }) {
                setMedia(value)
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func handleChannelElement(_ name: String, value: String) {
        guard !value.isEmpty else { return }
        // The channel's own `<image>` block has a `<title>` and a `<link>` of
        // its own, and they are not the feed's.
        guard !stack.contains("image") else { return }

        switch name {
        case "title":
            if feed.title == nil { feed.title = value }
        case "link":
            if feed.siteLink == nil, value.hasPrefix("http") { feed.siteLink = value }
        default:
            break
        }
    }

    private func setMedia(_ url: String) {
        guard current?.mediaURL == nil else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") || trimmed.hasPrefix("//") else { return }
        current?.mediaURL = trimmed
    }

    private func isImage(url: String, type: String?) -> Bool {
        if let type = type?.lowercased(), type.hasPrefix("image/") { return true }
        if type != nil { return false }
        let path = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif"].contains { path.contains($0) }
    }

    /// RSS authors are `email (Name)`; only the name is worth showing.
    private func cleanAuthor(_ raw: String) -> String {
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"),
              open < close else {
            return raw
        }
        let name = raw[raw.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? raw : name
    }

    /// An item with no text and no link is a structural artifact, not content.
    private func isUsable(_ item: ParsedItem) -> Bool {
        let hasText = !(item.title ?? "").isEmpty
            || !(item.summaryHTML ?? "").isEmpty
            || !(item.contentHTML ?? "").isEmpty
        return hasText || item.link != nil
    }
}

extension ParsedItem {

    /// Turns a parsed item into the app's own model.
    ///
    /// `siteLink` matters for the feeds that publish root-relative image paths
    /// — perfectly legal, and a broken image in every row without a base to
    /// resolve against.
    func article(sourceID: String, siteLink: String?, context: String? = nil) -> Article {
        let base = siteLink.flatMap(URL.init(string:))
        let linkURL = link.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }

        let body = bodyHTML
        let plain = body.map(HTMLText.plainText(from:)) ?? ""
        let cleanTitle = title.map { HTMLText.plainText(from: $0) } ?? ""

        var image = mediaURL.flatMap { raw -> URL? in
            // Protocol-relative URLs are common in syndicated content.
            let normalised = raw.hasPrefix("//") ? "https:" + raw : raw
            return URL(string: normalised, relativeTo: base)?.absoluteURL
        }
        if image == nil, let body {
            image = HTMLText.firstImageURL(in: body, relativeTo: base)
        }

        return Article(
            id: Article.stableID(sourceID: sourceID, guid: guid, link: link, fallback: cleanTitle + plain),
            sourceID: sourceID,
            title: cleanTitle,
            summary: plain,
            bodyHTML: body,
            link: linkURL,
            imageURL: image,
            author: author,
            published: FeedDate.parse(dateRaw),
            context: context
        )
    }
}

extension Article {

    /// The identity that has to survive a re-fetch.
    ///
    /// Preference order is deliberate: a `guid` is the publisher's own promise
    /// of stability, a link is nearly as good, and hashing the text is the last
    /// resort for feeds that offer neither. Falling through to the array index
    /// would be easier and would mark the whole feed unread on every refresh.
    static func stableID(sourceID: String, guid: String?, link: String?, fallback: String) -> String {
        if let guid, !guid.isEmpty { return sourceID + "|" + guid }
        if let link, !link.isEmpty,
           let canonical = URL(string: link).flatMap(URLCanonical.key(for:)) {
            return sourceID + "|" + canonical
        }
        if let link, !link.isEmpty { return sourceID + "|" + link }
        return sourceID + "|#" + StableHash.hex(String(fallback.prefix(220)))
    }
}
