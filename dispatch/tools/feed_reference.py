#!/usr/bin/env python3
"""A Python mirror of Dispatch's pure parsing logic.

There is no Swift compiler in this environment, and the parsing layer is where
the bugs in a feed reader actually live: entity handling, whitespace collapsing,
attribute matching, HTML that is not XML. Those are all pure functions of a
string, so they can be mirrored here and tested properly, on real-world inputs,
in a second — rather than discovered on a phone a week later when one source
quietly goes blank.

This file is a *reference*, not a port for its own sake. It exists to be tested
against by `test_feeds.py`, and it has to stay in step with the Swift. The
functions here are deliberately one-to-one with their Swift counterparts, named
the same, so a divergence is easy to see side by side:

    Swift                                   Python
    XMLSanitizer.rewriteEntities            rewrite_entities
    HTMLText.decodeEntities                 decode_entities
    HTMLText.plainText                      plain_text
    HTMLText.attributeValue                 attribute_value
    HTMLText.firstImageURL                  first_image_url
    TelegramFeed.messageChunks              message_chunks
    TelegramFeed.balancedDiv                balanced_div
    URLCanonical.key                        canonical_key
    Article.headline                        headline
    SteamText.html                          steam_html
    FeedDate.parse                          parse_date
"""

import re
from datetime import datetime, timezone
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

# --- Entities --------------------------------------------------------------

# Mirrors HTMLEntities.table. Kept to the same set on purpose: a name present
# in one and missing from the other is exactly the divergence these tests are
# meant to catch.
ENTITIES = {
    "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
    "apos": "'", "cent": "¢", "pound": "£", "yen": "¥", "euro": "€",
    "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
    "middot": "·", "bull": "•", "hellip": "…", "prime": "′", "Prime": "″",
    "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’",
    "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
    "dagger": "†", "Dagger": "‡", "permil": "‰", "lsaquo": "‹",
    "rsaquo": "›", "laquo": "«", "raquo": "»", "deg": "°", "plusmn": "±",
    "frac14": "¼", "frac12": "½", "frac34": "¾", "times": "×",
    "divide": "÷", "minus": "−", "ne": "≠", "le": "≤", "ge": "≥",
    "asymp": "≈", "infin": "∞", "sup2": "²", "sup3": "³", "micro": "µ",
    "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",
    "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦",
    "star": "☆", "check": "✓", "cross": "✗", "shy": "­",
    "ensp": " ", "emsp": " ", "thinsp": " ",
    "zwnj": "‌", "zwj": "‍", "lrm": "‎",
    "rlm": "‏", "iexcl": "¡", "iquest": "¿", "curren": "¤",
    "brvbar": "¦", "uml": "¨", "ordf": "ª", "not": "¬", "macr": "¯",
    "acute": "´", "cedil": "¸", "ordm": "º", "sup1": "¹", "szlig": "ß",
    "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã",
    "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
    "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
    "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
    "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô",
    "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù",
    "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý",
    "yuml": "ÿ", "Agrave": "À", "Aacute": "Á", "Acirc": "Â",
    "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
    "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê",
    "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î",
    "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
    "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
    "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
    "Yacute": "Ý", "THORN": "Þ", "thorn": "þ", "eth": "ð", "ETH": "Ð",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
    "epsilon": "ε", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ",
    "tau": "τ", "phi": "φ", "omega": "ω", "Omega": "Ω", "Delta": "Δ",
    "Sigma": "Σ", "Pi": "Π",
}

XML_BUILT_INS = {"amp", "lt", "gt", "quot", "apos"}


def replacement(name):
    """Mirrors HTMLEntities.replacement(for:)."""
    if name in ENTITIES:
        return ENTITIES[name]
    if not name.startswith("#"):
        return None
    digits = name[1:]
    try:
        if digits[:1] in ("x", "X"):
            value = int(digits[1:], 16)
        else:
            value = int(digits, 10)
    except (ValueError, IndexError):
        return None
    if value < 0 or value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
        return None
    return chr(value)


def is_forbidden_control(char):
    """Mirrors XMLSanitizer.isForbiddenControl."""
    value = ord(char)
    if value in (0x09, 0x0A, 0x0D):
        return False
    if value < 0x20:
        return True
    if 0x7F <= value <= 0x84 or 0x86 <= value <= 0x9F:
        return True
    if 0xD800 <= value <= 0xDFFF:
        return True
    if value in (0xFFFE, 0xFFFF):
        return True
    return False


def _read_entity_name(text, start):
    """Mirrors XMLSanitizer.readEntityName. Returns (name, next_index) or None."""
    cursor = start + 1
    limit = min(len(text), start + 35)
    name = []
    while cursor < limit:
        char = text[cursor]
        if char == ";":
            if not name:
                return None
            return "".join(name), cursor + 1
        if not (char.isalnum() or char == "#"):
            return None
        name.append(char)
        cursor += 1
    return None


def rewrite_entities(text):
    """Mirrors XMLSanitizer.rewriteEntities."""
    out = []
    index = 0
    while index < len(text):
        char = text[index]

        if is_forbidden_control(char):
            index += 1
            continue

        if char != "&":
            out.append(char)
            index += 1
            continue

        found = _read_entity_name(text, index)
        if found is None:
            out.append("&amp;")
            index += 1
            continue

        name, nxt = found
        if name in XML_BUILT_INS:
            out.append("&" + name + ";")
            index = nxt
            continue

        if name.startswith("#"):
            value = replacement(name)
            if value is not None and not is_forbidden_control(value[0]):
                out.append("&" + name + ";")
            index = nxt
            continue

        value = replacement(name)
        if value is not None:
            for scalar in value:
                if not is_forbidden_control(scalar):
                    out.append("&#%d;" % ord(scalar))
            index = nxt
            continue

        out.append("&amp;")
        index += 1

    return "".join(out)


def rewrite_declared_encoding(text):
    """Mirrors XMLSanitizer.rewriteDeclaredEncoding."""
    if not text.startswith("<?xml"):
        return text
    close = text.find("?>")
    if close < 0:
        return text
    declaration = text[:close + 2]
    if "encoding" not in declaration.lower():
        return text
    return '<?xml version="1.0" encoding="UTF-8"?>' + text[close + 2:]


def sanitize(raw):
    """Mirrors XMLSanitizer.sanitize."""
    text = raw.lstrip("﻿ \t\r\n")
    text = rewrite_declared_encoding(text)
    return rewrite_entities(text)


# --- Text ------------------------------------------------------------------

def decode_entities(text):
    """Mirrors HTMLText.decodeEntities."""
    if "&" not in text:
        return text

    out = []
    index = 0
    while index < len(text):
        char = text[index]
        if char != "&":
            out.append(char)
            index += 1
            continue

        limit = min(len(text), index + 34)
        semicolon = text.find(";", index + 1, limit)
        if semicolon < 0:
            out.append(char)
            index += 1
            continue

        name = text[index + 1:semicolon]
        value = replacement(name) if name else None
        if value is not None:
            out.append(value)
            index = semicolon + 1
        else:
            out.append(char)
            index += 1
    return "".join(out)


OPAQUE_TAGS = ["script", "style", "noscript", "iframe", "svg"]

BREAKING = {
    "br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
    "blockquote", "section", "article", "figure", "figcaption", "ul",
    "ol", "table", "hr", "pre",
}


def tag_name(tag_body):
    """Mirrors HTMLText.tagName."""
    name = []
    for char in tag_body:
        if char == "/" and not name:
            continue
        if char.isalnum():
            name.append(char)
        else:
            break
    return "".join(name).lower()


def _remove_sections(html, tag):
    """Mirrors HTMLText.removeSections."""
    out = []
    remainder = html
    lowered_tag = "<" + tag

    while True:
        open_at = remainder.lower().find(lowered_tag)
        if open_at < 0:
            break
        after = open_at + len(lowered_tag)
        if after < len(remainder) and (remainder[after].isalnum()):
            out.append(remainder[:after])
            remainder = remainder[after:]
            continue

        out.append(remainder[:open_at])
        rest = remainder[after:]
        close_at = rest.lower().find("</" + tag)
        if close_at >= 0:
            end = rest.find(">", close_at)
            if end >= 0:
                remainder = rest[end + 1:]
                continue
        remainder = ""
    out.append(remainder)
    return "".join(out)


def _remove_delimited(html, opener, closer):
    out = []
    remainder = html
    while True:
        start = remainder.find(opener)
        if start < 0:
            break
        out.append(remainder[:start])
        end = remainder.find(closer, start + len(opener))
        if end < 0:
            return "".join(out)
        remainder = remainder[end + len(closer):]
    out.append(remainder)
    return "".join(out)


def remove_opaque_sections(html):
    """Mirrors HTMLText.removeOpaqueSections."""
    text = html
    for tag in OPAQUE_TAGS:
        text = _remove_sections(text, tag)
    return _remove_delimited(text, "<!--", "-->")


def strip_tags(html, breaking_produce_newlines=True):
    """Mirrors HTMLText.stripTags."""
    out = []
    index = 0
    while index < len(html):
        if html[index] != "<":
            out.append(html[index])
            index += 1
            continue

        close = html.find(">", index)
        if close < 0:
            out.append(html[index])
            index += 1
            continue

        tag = html[index + 1:close]
        if breaking_produce_newlines:
            name = tag_name(tag)
            if name in BREAKING:
                out.append("\n")
                if name == "li" and not tag.startswith("/"):
                    out.append("• ")
        index = close + 1
    return "".join(out)


def collapse_whitespace(text):
    """Mirrors HTMLText.collapseWhitespace."""
    out = []
    pending_newlines = 0
    pending_space = False
    wrote_anything = False

    for char in text:
        if char in ("\n", "\r"):
            pending_newlines += 1
            pending_space = False
            continue
        if char in (" ", "\t", " "):
            pending_space = True
            continue

        if wrote_anything:
            if pending_newlines > 0:
                out.append("\n")
            elif pending_space:
                out.append(" ")
        pending_newlines = 0
        pending_space = False
        out.append(char)
        wrote_anything = True
    return "".join(out)


def plain_text(html):
    """Mirrors HTMLText.plainText."""
    text = remove_opaque_sections(html)
    text = text.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    text = strip_tags(text, True)
    text = decode_entities(text)
    return collapse_whitespace(text)


def attribute_value(name, tag_body):
    """Mirrors HTMLText.attributeValue."""
    remainder = tag_body
    consumed = 0

    while True:
        found = remainder.lower().find(name.lower())
        if found < 0:
            return None

        preceded_properly = found == 0 or not (
            remainder[found - 1].isalpha() or remainder[found - 1] == "-"
        )

        cursor = found + len(name)
        while cursor < len(remainder) and remainder[cursor] == " ":
            cursor += 1

        if not preceded_properly or cursor >= len(remainder) or remainder[cursor] != "=":
            consumed += found + len(name)
            remainder = remainder[found + len(name):]
            continue

        cursor += 1
        while cursor < len(remainder) and remainder[cursor] == " ":
            cursor += 1
        if cursor >= len(remainder):
            return None

        quote = remainder[cursor]
        if quote in ("\"", "'"):
            value_start = cursor + 1
            value_end = remainder.find(quote, value_start)
            if value_end < 0:
                return None
            return decode_entities(remainder[value_start:value_end])

        value_end = len(remainder)
        for stop in (" ", ">"):
            hit = remainder.find(stop, cursor)
            if hit >= 0:
                value_end = min(value_end, hit)
        return decode_entities(remainder[cursor:value_end])


TRACKING_HOSTS = ("feedburner", "doubleclick", "googleadservices", "scorecardresearch")


def is_likely_tracking_pixel(url):
    """Mirrors HTMLText.isLikelyTrackingPixel."""
    split = urlsplit(url)
    path = split.path.lower()
    host = (split.hostname or "").lower()
    if path.endswith(".gif") and ("pixel" in path or "spacer" in path):
        return True
    if any(marker in host for marker in TRACKING_HOSTS):
        return True
    return "/1x1" in path or "blank.gif" in path


def first_image_url(html):
    """Mirrors HTMLText.firstImageURL (without relative-URL resolution)."""
    remainder = html
    while True:
        open_at = remainder.lower().find("<img")
        if open_at < 0:
            return None
        close = remainder.find(">", open_at + 4)
        if close < 0:
            return None
        tag = remainder[open_at + 4:close]

        for attribute in ("data-original", "data-lazy-src", "data-src", "src"):
            value = attribute_value(attribute, tag)
            if not value or value.startswith("data:"):
                continue
            if is_likely_tracking_pixel(value):
                continue
            return value
        remainder = remainder[close + 1:]


# --- URLs ------------------------------------------------------------------

NOISE_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "utm_id", "utm_name", "fbclid", "gclid", "msclkid", "igshid", "mc_cid",
    "mc_eid", "ref", "referrer", "source", "amp", "__twitter_impression",
}


def canonical_key(url):
    """Mirrors URLCanonical.key."""
    split = urlsplit(url)
    if not split.hostname:
        return None

    kept = [(k, v) for k, v in parse_qsl(split.query, keep_blank_values=True)
            if k.lower() not in NOISE_PARAMS]
    kept.sort(key=lambda pair: pair[0])
    query = urlencode(kept) if kept else ""

    host = split.hostname.lower()
    if host.startswith("www."):
        host = host[4:]

    path = split.path
    while len(path) > 1 and path.endswith("/"):
        path = path[:-1]

    return host + path + ("?" + query if query else "")


# --- Headlines -------------------------------------------------------------

def headline(body, limit=140):
    """Mirrors Article.headline."""
    trimmed = body.strip()
    if not trimmed:
        return "Untitled"

    newline = trimmed.find("\n")
    if newline >= 0:
        first = trimmed[:newline].strip(" ")
        if len(first) >= 12:
            return first[:limit]

    if len(trimmed) <= limit:
        return trimmed

    window = trimmed[:limit]
    stop = max(window.rfind("."), window.rfind("!"), window.rfind("?"))
    if stop >= 20:
        return window[:stop + 1]

    space = window.rfind(" ")
    if space >= 0:
        return window[:space] + "…"
    return window + "…"


# --- Telegram --------------------------------------------------------------

def message_chunks(html):
    """Mirrors TelegramFeed.messageChunks."""
    starts = []
    cursor = 0
    marker = 'data-post="'
    while True:
        found = html.find(marker, cursor)
        if found < 0:
            break
        starts.append(found)
        cursor = found + len(marker)

    chunks = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(html)
        chunks.append(html[start:end])
    return chunks


def balanced_div(html, class_containing):
    """Mirrors TelegramFeed.balancedDiv."""
    search_from = 0
    while True:
        hit = html.find(class_containing, search_from)
        if hit < 0:
            return None
        search_from = hit + len(class_containing)

        tag_start = html.rfind("<", 0, hit)
        if tag_start < 0:
            continue
        if not html[tag_start:].startswith("<div"):
            continue
        tag_end = html.find(">", tag_start)
        if tag_end < 0:
            return None

        content_start = tag_end + 1
        depth = 1
        cursor = content_start

        while cursor < len(html) and depth > 0:
            nxt = html.find("<", cursor)
            if nxt < 0:
                return html[content_start:]
            if html[nxt:].startswith("</div"):
                depth -= 1
                if depth == 0:
                    return html[content_start:nxt]
                cursor = nxt + 5
            elif html[nxt:].startswith("<div"):
                depth += 1
                cursor = nxt + 4
            else:
                cursor = nxt + 1
        return html[content_start:]


def last_attribute_value(name, html):
    """Mirrors TelegramFeed.lastAttributeValue."""
    result = None
    cursor = 0
    marker = name + '="'
    while True:
        open_at = html.find(marker, cursor)
        if open_at < 0:
            break
        cursor = open_at + len(marker)
        close = html.find('"', cursor)
        if close < 0:
            break
        value = html[cursor:close]
        if value:
            result = decode_entities(value)
    return result


def telegram_image_url(chunk):
    """Mirrors TelegramFeed.imageURL."""
    remainder = chunk
    while True:
        marker = remainder.find("background-image:")
        if marker < 0:
            return None
        rest = remainder[marker + len("background-image:"):]
        open_at = rest.find("url(")
        if open_at < 0:
            return None
        after_open = rest[open_at + 4:]
        close = after_open.find(")")
        if close < 0:
            return None
        raw = after_open[:close].strip("'\" ")
        decoded = decode_entities(raw)
        if decoded.startswith("http"):
            return decoded
        remainder = rest[open_at + 4:]


def normalize_channel(raw):
    """Mirrors TelegramFeed.normalizeChannel."""
    text = raw.strip()
    for prefix in ("https://", "http://"):
        if text.lower().startswith(prefix):
            text = text[len(prefix):]
    for prefix in ("t.me/", "telegram.me/", "telegram.dog/"):
        if text.lower().startswith(prefix):
            text = text[len(prefix):]
    if text.lower().startswith("s/"):
        text = text[2:]
    if text.startswith("@"):
        text = text[1:]
    if "/" in text:
        text = text[:text.index("/")]
    if "?" in text:
        text = text[:text.index("?")]
    return text


def parse_telegram(html, source_id="tg"):
    """Mirrors TelegramFeed.parse, returning plain dicts."""
    articles = []
    for chunk in message_chunks(html):
        post_id = attribute_value("data-post", chunk)
        if not post_id:
            continue
        body = balanced_div(chunk, "js-message_text")
        text = plain_text(body) if body is not None else ""
        image = telegram_image_url(chunk)
        published = last_attribute_value("datetime", chunk)

        if not text and image is None:
            continue

        articles.append({
            "id": source_id + "|" + post_id,
            "summary": text if text else "(no caption)",
            "image": image,
            "published": published,
            "link": "https://t.me/" + post_id,
        })
    return articles


# --- X handles -------------------------------------------------------------

def normalize_handle(raw):
    """Mirrors XBridge.normalizeHandle."""
    text = raw.strip()
    for prefix in ("https://", "http://"):
        if text.lower().startswith(prefix):
            text = text[len(prefix):]
    if text.lower().startswith("www."):
        text = text[4:]
    for prefix in ("x.com/", "twitter.com/", "mobile.twitter.com/", "nitter.net/"):
        if text.lower().startswith(prefix):
            text = text[len(prefix):]
    if text.startswith("@"):
        text = text[1:]
    if "/" in text:
        text = text[:text.index("/")]
    if "?" in text:
        text = text[:text.index("?")]

    kept = []
    for char in text:
        if char.isalnum() or char == "_":
            kept.append(char)
        else:
            break
    return "".join(kept)


# --- Steam BBCode ----------------------------------------------------------

def _rewrite_url_tags(text):
    """Mirrors SteamText.rewriteURLTags."""
    out = []
    remainder = text
    while True:
        open_at = remainder.lower().find("[url")
        if open_at < 0:
            break
        out.append(remainder[:open_at])
        tag_end = remainder.find("]", open_at + 4)
        if tag_end < 0:
            out.append(remainder[open_at:])
            return "".join(out)

        attribute = remainder[open_at + 4:tag_end]
        href = attribute[1:].strip("\"' ") if attribute.startswith("=") else ""

        body_start = tag_end + 1
        close_at = remainder.lower().find("[/url]", body_start)
        if close_at < 0:
            out.append(remainder[body_start:])
            return "".join(out)

        label = remainder[body_start:close_at]
        target = href if href else label
        out.append('<a href="%s">%s</a>' % (target, label))
        remainder = remainder[close_at + len("[/url]"):]
    out.append(remainder)
    return "".join(out)


def _rewrite_simple(text, tag, opener, closer, wraps_content):
    out = []
    remainder = text
    open_marker = "[%s]" % tag
    close_marker = "[/%s]" % tag
    while True:
        start = remainder.lower().find(open_marker)
        if start < 0:
            break
        out.append(remainder[:start])
        end = remainder.lower().find(close_marker, start + len(open_marker))
        if end < 0:
            out.append(remainder[start:])
            return "".join(out)
        body = remainder[start + len(open_marker):end].strip()
        out.append(opener + (body if wraps_content else "") + closer)
        remainder = remainder[end + len(close_marker):]
    out.append(remainder)
    return "".join(out)


STEAM_PAIRS = [
    ("b", "<strong>", "</strong>"),
    ("i", "<em>", "</em>"),
    ("u", "<u>", "</u>"),
    ("strike", "<s>", "</s>"),
    ("h1", "<h3>", "</h3>"),
    ("h2", "<h3>", "</h3>"),
    ("h3", "<h3>", "</h3>"),
    ("list", "<ul>", "</ul>"),
    ("olist", "<ol>", "</ol>"),
    ("quote", "<blockquote>", "</blockquote>"),
    ("code", "<pre>", "</pre>"),
    ("noparse", "", ""),
    ("spoiler", "", ""),
]


def steam_html(contents):
    """Mirrors SteamText.html."""
    if "<p>" in contents or "<br" in contents or "<div" in contents:
        return contents

    text = _rewrite_url_tags(contents)
    text = _rewrite_simple(text, "img", '<img src="', '">', True)

    for tag, opener, closer in STEAM_PAIRS:
        text = re.sub(r"\[%s\]" % tag, opener, text, flags=re.IGNORECASE)
        text = re.sub(r"\[/%s\]" % tag, closer, text, flags=re.IGNORECASE)

    text = text.replace("[*]", "<li>")
    text = re.sub(r"\[hr\]", "<hr>", text, flags=re.IGNORECASE)
    text = re.sub(r"\[/hr\]", "", text, flags=re.IGNORECASE)
    text = text.replace("\r\n", "\n").replace("\n", "<br>")
    return text


# --- Dates -----------------------------------------------------------------

DATE_FORMATS = [
    "%a, %d %b %Y %H:%M:%S %z",
    "%a, %d %b %Y %H:%M %z",
    "%d %b %Y %H:%M:%S %z",
    "%Y-%m-%dT%H:%M:%S.%f%z",
    "%Y-%m-%dT%H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S %z",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d",
]

ZONE_REPLACEMENTS = [
    (" UT", " +0000"), (" GMT", " +0000"), (" UTC", " +0000"),
    (" Z", " +0000"), (" EST", " -0500"), (" EDT", " -0400"),
    (" CST", " -0600"), (" CDT", " -0500"), (" MST", " -0700"),
    (" MDT", " -0600"), (" PST", " -0800"), (" PDT", " -0700"),
]


def normalize_zone(raw):
    """Mirrors FeedDate.normaliseZone."""
    for abbreviation, offset in ZONE_REPLACEMENTS:
        if raw.endswith(abbreviation):
            return raw[:-len(abbreviation)] + offset
    return raw


def parse_date(raw):
    """Mirrors FeedDate.parse. Returns a timezone-aware datetime or None."""
    if raw is None:
        return None
    trimmed = raw.strip()
    if not trimmed:
        return None

    normalized = normalize_zone(trimmed)
    for fmt in DATE_FORMATS:
        try:
            parsed = datetime.strptime(normalized, fmt)
        except ValueError:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed

    try:
        seconds = float(trimmed)
    except ValueError:
        return None
    if seconds > 100_000_000:
        return datetime.fromtimestamp(seconds, tz=timezone.utc)
    return None


# --- Topic classification --------------------------------------------------
#
# The lexicon is *read out of the Swift* rather than copied here. Two hundred
# weighted terms maintained in two files would diverge within a week, and the
# divergence would be invisible: the tests would keep passing against a table
# the app no longer uses. Parsing the real one means a term added to the app is
# a term the tests see.

import os

LEXICON_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ios", "Dispatch", "Net", "TopicLexicon.swift",
)

TITLE_WEIGHT = 2.2
MINIMUM_SCORE = 3.0
DECISIVE_MARGIN = 0.35
SOURCE_PRIOR_WEIGHT = 1.25

TERM_RE = re.compile(r'\("([^"]+)",\s*([0-9.]+)\)')


def load_lexicon(path=LEXICON_PATH):
    """Mirrors TopicLexicon. Returns {topic: [(term, weight), ...]}."""
    source = open(path, encoding="utf-8").read()
    tables = {}
    for topic in ("war", "politics", "economics"):
        marker = "static let %s: [(String, Double)] = [" % topic
        start = source.index(marker) + len(marker)
        end = source.index("]", start)
        tables[topic] = [(term, float(weight))
                         for term, weight in TERM_RE.findall(source[start:end])]
    return tables


def build_lexicon(terms):
    """Mirrors TopicClassifier.build — words and phrases split apart."""
    words, phrases = {}, []
    for term, weight in terms:
        if " " in term:
            phrases.append((term, term.split(" ", 1)[0], weight))
        else:
            words[term] = max(words.get(term, 0.0), weight)
    return words, phrases


def normalise(text):
    """Mirrors TopicClassifier.normalise."""
    out = []
    for char in text.lower():
        if char.isalnum() or char in ("-", "&"):
            out.append(char)
        else:
            out.append(" ")
    return " ".join("".join(out).split())


def field(raw):
    """Mirrors TopicClassifier.field. Returns (text, loose, words)."""
    text = normalise(raw)
    if "-" not in text:
        return text, text, tokens(text)
    loose = normalise(text.replace("-", " "))
    return text, loose, tokens(text) | tokens(loose)


def tokens(normalised):
    """Mirrors TopicClassifier.tokens."""
    return set(normalised.split(" ")) if normalised else set()


def classify(title, body, prior, fallback, tables=None):
    """Mirrors TopicClassifier.classify.

    Returns (topic, confidence, evidence, is_fallback).
    """
    tables = tables if tables is not None else load_lexicon()

    title_text, title_loose, title_words = field(title)
    body_text, body_loose, body_words = field(body[:1400])

    scores, hits = {}, {}

    for topic in ("war", "politics", "economics"):
        words, phrases = build_lexicon(tables[topic])
        score = 0.0
        matched = []

        for word, weight in words.items():
            if word in title_words:
                score += weight * TITLE_WEIGHT
                matched.append((word, weight * TITLE_WEIGHT))
            elif word in body_words:
                score += weight
                matched.append((word, weight))

        for phrase, head, weight in phrases:
            in_title = head in title_words
            in_body = head in body_words
            if not (in_title or in_body):
                continue
            if in_title and (phrase in title_text or phrase in title_loose):
                score += weight * TITLE_WEIGHT
                matched.append((phrase, weight * TITLE_WEIGHT))
            elif in_body and (phrase in body_text or phrase in body_loose):
                score += weight
                matched.append((phrase, weight))

        scores[topic] = score
        hits[topic] = matched

    if prior:
        scores[prior] = scores.get(prior, 0.0) + SOURCE_PRIOR_WEIGHT

    ranked = sorted(scores.items(), key=lambda pair: (-pair[1], pair[0]))
    winner, top = ranked[0]

    if top < MINIMUM_SCORE:
        return fallback, 0.0, [], True

    runner_up = ranked[1][1] if len(ranked) > 1 else 0.0
    margin = (top - runner_up) / top
    evidence = [term for term, _ in sorted(hits[winner], key=lambda pair: -pair[1])[:4]]
    return winner, min(1.0, margin / DECISIVE_MARGIN), evidence, False


def is_local_host(host_text):
    """Mirrors XBridge.isLocalHost."""
    bare = host_text.split(":")[0].lower() if host_text else ""
    if bare == "localhost" or bare.endswith(".local"):
        return True
    if bare.startswith("192.168.") or bare.startswith("10.") or bare.startswith("127."):
        return True
    if bare.startswith("172."):
        parts = bare.split(".")
        if len(parts) >= 2 and parts[1].isdigit() and 16 <= int(parts[1]) <= 31:
            return True
    return False


def normalized_host(host):
    """Mirrors XBridge.normalizedHost."""
    text = host.strip()
    if not text:
        return ""
    while text.endswith("/"):
        text = text[:-1]
    lowered = text.lower()
    if lowered.startswith("http://") or lowered.startswith("https://"):
        return text
    return ("http://" if is_local_host(text) else "https://") + text


def links_in(html):
    """Mirrors HTMLText.links. Returns [(href, text), ...]."""
    found = []
    remainder = html
    while True:
        open_at = remainder.lower().find("<a")
        if open_at < 0:
            break
        after = open_at + 2
        if after < len(remainder) and remainder[after].isalnum():
            remainder = remainder[after:]
            continue
        close = remainder.find(">", after)
        if close < 0:
            break
        tag = remainder[after:close]
        rest = remainder[close + 1:]

        text = ""
        end = rest.lower().find("</a")
        if end >= 0:
            text = plain_text(rest[:end])

        href = attribute_value("href", tag)
        if href:
            found.append((href.strip(), text))
        remainder = rest
    return found


SHARE_MARKERS = ("sharer", "/intent/", "/share", "share.php", "/submit",
                 "addtoany", "printfriendly", "whatsapp.com", "/cdn-cgi/")

LABEL_HINTS = ("go to article", "read the full", "read more at", "source:")


def _bare_host(url):
    host = urlsplit(url).hostname or ""
    host = host.lower()
    return host[4:] if host.startswith("www.") else host


def outbound_link(html, excluding_host):
    """Mirrors HTMLText.outboundLink."""
    home = (excluding_host or "").lower()
    if home.startswith("www."):
        home = home[4:]

    candidates = []
    for href, text in links_in(html):
        scheme = urlsplit(href).scheme.lower()
        if scheme not in ("http", "https"):
            continue
        if _bare_host(href) == home:
            continue
        if any(marker in href.lower() for marker in SHARE_MARKERS):
            continue
        candidates.append((href, text))

    for href, text in candidates:
        lowered = text.lower()
        if any(hint in lowered for hint in LABEL_HINTS):
            return href
    return candidates[0][0] if candidates else None


# --- Steam placeholders, leftover tags and script detection -----------------

STEAM_PLACEHOLDERS = ("{STEAM_CLAN_IMAGE}", "{STEAM_CLAN_LOC_IMAGE}")
STEAM_CDN = "https://clan.cloudflare.steamstatic.com/images"


def expand_placeholders(text):
    """Mirrors SteamText.expandPlaceholders."""
    out = text
    for placeholder in STEAM_PLACEHOLDERS:
        out = out.replace(placeholder, STEAM_CDN)
    return out


def _is_tag_like(body):
    """Mirrors SteamText.isTagLike."""
    name = body[1:] if body.startswith("/") else body
    if not name:
        return False
    head = ""
    for char in name:
        if char in ("=", " "):
            break
        head += char
    if not head or len(head) > 20:
        return False
    return all(c.isalpha() and c.islower() for c in head)


def strip_remaining_tags(text):
    """Mirrors SteamText.stripRemainingTags."""
    out = []
    remainder = text
    while True:
        open_at = remainder.find("[")
        if open_at < 0:
            break
        close = remainder.find("]", open_at)
        if close < 0:
            break
        body = remainder[open_at + 1:close]
        if _is_tag_like(body):
            out.append(remainder[:open_at])
        else:
            out.append(remainder[:close + 1])
        remainder = remainder[close + 1:]
    out.append(remainder)
    return "".join(out)


NON_LATIN_RANGES = (
    (0x0400, 0x052F), (0x0590, 0x05FF), (0x0600, 0x06FF), (0x0750, 0x077F),
    (0x0E00, 0x0E7F), (0x1100, 0x11FF), (0xAC00, 0xD7AF), (0x3040, 0x30FF),
    (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF),
)


def is_predominantly_latin(text, threshold=0.5):
    """Mirrors TextScript.isPredominantlyLatin."""
    latin = other = 0
    for char in text:
        if not char.isalpha():
            continue
        code = ord(char)
        if any(low <= code <= high for low, high in NON_LATIN_RANGES):
            other += 1
        else:
            latin += 1
    total = latin + other
    if total < 8:
        return True
    return latin / total >= threshold


# --- The generated brief ----------------------------------------------------
#
# The Claude API request is built entirely from strings the digest already
# shows, and the constants are read *out of the Swift* for the same reason the
# lexicon is: a copied endpoint or version string would drift silently. The
# prompt builder and the input key are mirrored properly, because those are the
# two pieces of pure logic — a byte of drift in the key means summaries
# regenerate (and bill) on every refresh.

SUMMARY_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ios", "Dispatch", "Net", "SummaryAPI.swift",
)

SUMMARY_CONST_RE = re.compile(r'static let (\w+) = (?:"([^"]*)"|(\d+))')


def summary_constants(path=SUMMARY_PATH):
    """The `static let` constants of SummaryAPI, as {name: value}."""
    source = open(path, encoding="utf-8").read()
    constants = {}
    for name, text, number in SUMMARY_CONST_RE.findall(source):
        constants[name] = int(number) if number else text
    return constants


def stable_hash_hex(text):
    """Mirrors StableHash.hex — FNV-1a over UTF-8, lowercase hex, no padding."""
    value = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 0x00000100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%x" % value


def brief_input_key(article_ids):
    """Mirrors SummaryStore.inputKey — order-independent by design."""
    return stable_hash_hex("\n".join(sorted(article_ids)))


def summary_prompt(topic, headlines):
    """Mirrors SummaryAPI.prompt. `headlines` is [(title, source, age-or-None)]."""
    lines = ["Section: %s" % topic, "Headlines, newest first:"]
    for title, source, age in headlines:
        suffix = ", %s" % age if age is not None else ""
        lines.append("- [%s%s] %s" % (source, suffix, title))
    return "\n".join(lines)
