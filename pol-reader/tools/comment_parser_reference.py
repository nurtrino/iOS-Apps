"""Reference implementation of the 4chan comment parser.

This is the same algorithm as ios/PolReader/Text/CommentParser.swift, kept in a
language that can actually be run in this environment. There is no Swift
toolchain here, so the Swift version is only ever compiled by CI; this file is
where the algorithm is proven correct before it is transliterated.

If you change one, change both, and re-run tools/test_parser.py.

4chan serves comments as a very small HTML subset:

    <br>                                    line break
    <span class="quote">&gt;text</span>     greentext
    <a href="#p123" class="quotelink">      reply link within the thread
    <a href="/pol/thread/1#p2" ...>         cross-thread link
    <a href="//boards.4chan.org/g/" ...>    cross-board link
    <span class="deadlink">&gt;&gt;1</span> quoted post that no longer exists
    <s>text</s>                             spoiler
    <pre class="prettyprint">               code block
    <span class="sjis">                     Shift-JIS art (needs monospace)
    <wbr>                                   word-break hint inside long tokens
    <b> <strong> <i> <em> <u>               emphasis
    &gt; &lt; &amp; &#039; &#x27;            entities

Nothing here may import a UI framework: this module is shared between the iOS
and Android ports and is the part most worth testing in isolation.
"""

# --- Style constructors -----------------------------------------------------
#
# A style is a tuple whose first element names it. Tuples rather than classes so
# that test assertions can compare them literally.

ITALIC = ("italic",)
BOLD = ("bold",)
UNDERLINE = ("underline",)
SPOILER = ("spoiler",)
GREENTEXT = ("greentext",)
DEADLINK = ("deadlink",)
INLINE_CODE = ("code",)
SHIFT_JIS = ("sjis",)


def link(url):
    return ("link", url)


def quotelink(board, thread, post):
    """A >>123 style reference. `board` and `thread` are None when the target is
    in the thread currently being read, which is the common case."""
    return ("quotelink", board, thread, post)


def boardlink(board):
    """A >>>/g/ style reference to a board rather than a post."""
    return ("boardlink", board)


class Span:
    """A styled range over a paragraph's text, in decoded-character offsets."""

    __slots__ = ("start", "length", "style")

    def __init__(self, start, length, style):
        self.start = start
        self.length = length
        self.style = style

    @property
    def end(self):
        return self.start + self.length

    def __repr__(self):
        return "Span(%d, %d, %r)" % (self.start, self.length, self.style)

    def __eq__(self, other):
        return (
            isinstance(other, Span)
            and self.start == other.start
            and self.length == other.length
            and self.style == other.style
        )


class Paragraph:
    __slots__ = ("text", "spans")

    def __init__(self, text, spans):
        self.text = text
        self.spans = spans

    kind = "paragraph"

    def __repr__(self):
        return "Paragraph(%r, %r)" % (self.text, self.spans)


class CodeBlock:
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text

    kind = "code"

    def __repr__(self):
        return "CodeBlock(%r)" % (self.text,)


# --- Entities ---------------------------------------------------------------

_NAMED_ENTITIES = {
    "lt": "<", "gt": ">", "amp": "&", "quot": '"', "apos": "'",
    "nbsp": " ", "ndash": "–", "mdash": "—",
    "hellip": "…", "laquo": "«", "raquo": "»",
    "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
    "deg": "°", "middot": "·", "bull": "•",
    "trade": "™", "copy": "©", "reg": "®",
    "eacute": "é", "egrave": "è", "uuml": "ü",
    "ouml": "ö", "auml": "ä", "szlig": "ß",
    "ccedil": "ç", "ntilde": "ñ", "pound": "£",
    "euro": "€", "yen": "¥", "sect": "§", "para": "¶",
    "times": "×", "divide": "÷", "plusmn": "±",
    "frac12": "½", "frac14": "¼", "sup2": "²", "sup3": "³",
}

# A bare "&" in prose is common. Without a bound on the lookahead, scanning for
# the closing ";" swallows the rest of the line.
_MAX_ENTITY_LEN = 12


def decode_entity(s, i):
    """Decode the entity starting at s[i] == '&'.

    Returns (text, next_index), or None when this is not an entity, in which
    case the caller emits a literal '&'.
    """
    limit = min(len(s), i + _MAX_ENTITY_LEN + 2)
    semi = -1
    for j in range(i + 1, limit):
        c = s[j]
        if c == ";":
            semi = j
            break
        # Entities are alphanumeric (plus a leading '#'); anything else means
        # this '&' was just an ampersand.
        if not (c.isalnum() or (c == "#" and j == i + 1)):
            return None
    if semi <= i + 1:
        return None

    body = s[i + 1:semi]
    if body.startswith("#"):
        try:
            if body[1:2] in ("x", "X"):
                code = int(body[2:], 16)
            else:
                code = int(body[1:], 10)
        except ValueError:
            return None
        # Reject values outside the Unicode scalar range and surrogates.
        if code <= 0 or code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
            return None
        return chr(code), semi + 1

    if body in _NAMED_ENTITIES:
        return _NAMED_ENTITIES[body], semi + 1
    return None


def decode_entities(s):
    """Decode every entity in a plain string (used for href attributes)."""
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "&":
            decoded = decode_entity(s, i)
            if decoded is not None:
                out.append(decoded[0])
                i = decoded[1]
                continue
        out.append(c)
        i += 1
    return "".join(out)


# --- Tag scanning -----------------------------------------------------------


def parse_tag(s, i):
    """Parse the tag starting at s[i] == '<'.

    Returns (name, attrs, is_closing, next_index), or None when this '<' is not
    the start of a tag and must be treated as literal text.

    The guard on the character after '<' is what stops `a < b and c > d` from
    being read as a tag and swallowing everything up to the '>'.
    """
    n = len(s)
    if i + 1 >= n:
        return None
    c = s[i + 1]
    is_closing = c == "/"
    if is_closing:
        if i + 2 >= n or not s[i + 2].isalpha():
            return None
    elif not c.isalpha():
        return None

    j = i + 2 if is_closing else i + 1
    # Tag name.
    name_start = j
    while j < n and (s[j].isalnum() or s[j] in "-_"):
        j += 1
    name = s[name_start:j].lower()
    if not name:
        return None

    attrs = {}
    while j < n:
        while j < n and s[j].isspace():
            j += 1
        if j >= n:
            return None
        if s[j] == ">":
            return name, attrs, is_closing, j + 1
        if s[j] == "/":
            j += 1
            continue
        # Attribute name.
        attr_start = j
        while j < n and not s[j].isspace() and s[j] not in "=>":
            j += 1
        attr_name = s[attr_start:j].lower()
        while j < n and s[j].isspace():
            j += 1
        value = ""
        if j < n and s[j] == "=":
            j += 1
            while j < n and s[j].isspace():
                j += 1
            if j < n and s[j] in "\"'":
                quote = s[j]
                j += 1
                value_start = j
                while j < n and s[j] != quote:
                    j += 1
                value = s[value_start:j]
                j += 1  # closing quote
            else:
                value_start = j
                while j < n and not s[j].isspace() and s[j] != ">":
                    j += 1
                value = s[value_start:j]
        if attr_name:
            attrs[attr_name] = value
    # Ran off the end without a '>': not a tag.
    return None


# --- Link classification ----------------------------------------------------

_SAFE_SCHEMES = ("http://", "https://")
_BOARD_HOSTS = ("boards.4chan.org", "boards.4channel.org")


def classify_href(href, css_classes):
    """Turn an <a> tag into a style, or None if the link should be dropped.

    Quotelinks are recognised by shape before any scheme check, because their
    hrefs are relative ('#p123', '/pol/thread/1#p2') and would otherwise fail
    an http(s) allowlist that exists to keep 'javascript:' out of a comment
    body that is entirely untrusted input.
    """
    href = decode_entities(href or "").strip()
    if not href:
        return None

    is_quotelink = "quotelink" in css_classes

    # #p123456789 -- same thread.
    if href.startswith("#p"):
        digits = href[2:]
        if digits.isdigit():
            return quotelink(None, None, int(digits))
        return None

    path = href
    host = None
    if path.startswith("//"):
        rest = path[2:]
        slash = rest.find("/")
        host = rest[:slash] if slash >= 0 else rest
        path = rest[slash:] if slash >= 0 else "/"
    else:
        for scheme in _SAFE_SCHEMES:
            if path.lower().startswith(scheme):
                rest = path[len(scheme):]
                slash = rest.find("/")
                candidate_host = rest[:slash] if slash >= 0 else rest
                if candidate_host in _BOARD_HOSTS:
                    host = candidate_host
                    path = rest[slash:] if slash >= 0 else "/"
                break

    if host is None and not path.startswith("/"):
        # An ordinary absolute URL to somewhere else.
        low = href.lower()
        if low.startswith(_SAFE_SCHEMES):
            return link(href)
        return None

    if host is not None and host not in _BOARD_HOSTS:
        low = href.lower()
        if low.startswith(_SAFE_SCHEMES):
            return link(href)
        return None

    # Board-relative path: /board/, /board/thread/123, /board/thread/123#p456
    parts = [p for p in path.split("/") if p]
    if not parts:
        return None
    board = parts[0]
    if len(parts) == 1:
        return boardlink(board)
    if len(parts) >= 3 and parts[1] == "thread":
        tail = parts[2]
        anchor = None
        if "#p" in tail:
            tail, anchor = tail.split("#p", 1)
        if not tail.isdigit():
            return None
        thread_no = int(tail)
        post_no = int(anchor) if anchor and anchor.isdigit() else thread_no
        return quotelink(board, thread_no, post_no)

    if is_quotelink:
        return boardlink(board)
    if href.lower().startswith(_SAFE_SCHEMES):
        return link(href)
    return None


def classify_span(css_classes):
    if "quote" in css_classes:
        return GREENTEXT
    if "deadlink" in css_classes:
        return DEADLINK
    if "sjis" in css_classes:
        return SHIFT_JIS
    return None


# --- The parser -------------------------------------------------------------

_EMPHASIS = {
    "b": BOLD, "strong": BOLD,
    "i": ITALIC, "em": ITALIC,
    "u": UNDERLINE,
    "s": SPOILER, "strike": SPOILER, "del": SPOILER,
    "code": INLINE_CODE,
}

# A closing tag pops the innermost element opened by the *same group*, not the
# innermost element with a matching style. Matching on style cannot work: an
# element may carry no style at all (an unknown <span>, or an <a> whose href was
# rejected), and those still have to be popped by their closing tag or they leak
# up the stack and corrupt every range that follows.
_CLOSE_GROUP = {
    "strong": "b", "em": "i", "strike": "s", "del": "s",
}

_BLOCK_BREAKING = ("p", "div")


def _group(tag_name):
    return _CLOSE_GROUP.get(tag_name, tag_name)


def parse(html):
    """Parse a comment body into a list of Paragraph and CodeBlock."""
    if not html:
        return []

    blocks = []
    text = []          # characters of the paragraph being built
    spans = []         # completed spans for this paragraph
    # Open elements, innermost last: [(group, style_or_None, start_offset), ...]
    open_styles = []

    def flush_paragraph():
        nonlocal text, spans, open_styles
        # Close every open style at the end of the line, then reopen it at the
        # start of the next one, so emphasis survives a <br> without a span
        # that runs past the end of its own paragraph.
        length = len(text)
        for group, style, start in open_styles:
            if style is not None and length > start:
                spans.append(Span(start, length - start, style))
        emit(("".join(text)), spans)
        text = []
        spans = []
        open_styles = [(group, style, 0) for group, style, _ in open_styles]

    def emit(raw, raw_spans):
        # Trim surrounding whitespace and shift the spans to match, or every
        # range drifts by the number of leading spaces removed.
        lead = 0
        while lead < len(raw) and raw[lead].isspace():
            lead += 1
        trail = len(raw)
        while trail > lead and raw[trail - 1].isspace():
            trail -= 1
        trimmed = raw[lead:trail]
        if not trimmed:
            return  # whitespace-only paragraph
        shifted = []
        for span in raw_spans:
            start = span.start - lead
            end = span.end - lead
            start = max(0, start)
            end = min(len(trimmed), end)
            if end > start:
                shifted.append(Span(start, end - start, span.style))
        shifted.sort(key=lambda s: (s.start, s.length))
        blocks.append(Paragraph(trimmed, shifted))

    def close_group(group):
        """Close the innermost element opened by `group`."""
        for idx in range(len(open_styles) - 1, -1, -1):
            open_group, style, start = open_styles[idx]
            if open_group == group:
                length = len(text) - start
                if style is not None and length > 0:
                    spans.append(Span(start, length, style))
                del open_styles[idx]
                return

    i = 0
    n = len(html)
    while i < n:
        c = html[i]

        if c == "<":
            tag = parse_tag(html, i)
            if tag is None:
                text.append("<")  # stray '<' in prose
                i += 1
                continue
            name, attrs, is_closing, next_i = tag
            i = next_i

            if name == "wbr":
                # A word-break hint. It must vanish leaving nothing behind:
                # 4chan injects it into long URLs and filenames, and inserting
                # any character here corrupts them.
                continue

            if name == "br":
                flush_paragraph()
                continue

            if name == "pre":
                if not is_closing:
                    flush_paragraph()
                    code_text, i = _read_code_block(html, i)
                    if code_text.strip():
                        blocks.append(CodeBlock(code_text))
                continue

            if name in _BLOCK_BREAKING:
                flush_paragraph()
                continue

            if name == "a":
                if is_closing:
                    close_group("a")
                else:
                    classes = (attrs.get("class") or "").lower().split()
                    # A rejected href (javascript:, mailto:, malformed) opens
                    # with no style: the anchor text still belongs in the
                    # output, only the link goes away.
                    style = classify_href(attrs.get("href"), classes)
                    open_styles.append(("a", style, len(text)))
                continue

            if name == "span":
                if is_closing:
                    close_group("span")
                else:
                    classes = (attrs.get("class") or "").lower().split()
                    open_styles.append(("span", classify_span(classes), len(text)))
                continue

            if name in _EMPHASIS:
                if is_closing:
                    close_group(_group(name))
                else:
                    open_styles.append((_group(name), _EMPHASIS[name], len(text)))
                continue

            # Unknown tag: ignore the tag, keep the text inside it.
            continue

        if c == "&":
            decoded = decode_entity(html, i)
            if decoded is not None:
                text.append(decoded[0])
                i = decoded[1]
                continue
            text.append("&")
            i += 1
            continue

        if c == "\r":
            i += 1
            continue

        if c == "\n":
            flush_paragraph()
            i += 1
            continue

        text.append(c)
        i += 1

    # Close whatever is still open at the end of the body.
    length = len(text)
    for group, style, start in open_styles:
        if style is not None and length > start:
            spans.append(Span(start, length - start, style))
    emit("".join(text), spans)

    return blocks


def _read_code_block(html, i):
    """Consume up to and including the matching </pre>. Returns (text, index)."""
    out = []
    n = len(html)
    while i < n:
        if html[i] == "<":
            tag = parse_tag(html, i)
            if tag is not None:
                name, _attrs, is_closing, next_i = tag
                if name == "pre" and is_closing:
                    return "".join(out), next_i
                if name == "br":
                    out.append("\n")
                    i = next_i
                    continue
                if name == "wbr":
                    i = next_i
                    continue
                # Any other markup inside a code block is dropped, its text kept.
                i = next_i
                continue
            out.append("<")
            i += 1
            continue
        if html[i] == "&":
            decoded = decode_entity(html, i)
            if decoded is not None:
                out.append(decoded[0])
                i = decoded[1]
                continue
        out.append(html[i])
        i += 1
    return "".join(out), i


# --- Quotelink extraction ---------------------------------------------------


def extract_quoted_posts(html):
    """Every post number this comment quotes, in order, without duplicates.

    Used to build the backlink index. Runs the full parser rather than a regex
    so that a '>>123' appearing inside a code block or a dropped link does not
    register as a reply.
    """
    seen = []
    for block in parse(html):
        if block.kind != "paragraph":
            continue
        for span in block.spans:
            if span.style and span.style[0] == "quotelink":
                _, board, _thread, post = span.style
                if board is None and post not in seen:
                    seen.append(post)
    return seen


def is_quote_only_paragraph(paragraph, targets):
    """True when this paragraph is nothing but quotelinks to `targets`.

    Used by the threaded view. 4chan posts open with ">>123" naming the post
    being answered, which is the whole addressing mechanism on a flat board.
    Once a reply is drawn *underneath* the post it answers, that line is pure
    noise — Reddit and HN don't print "re: parent" above every comment.

    Only dropped when the paragraph is *entirely* quotelinks pointing at an
    ancestor: a line like ">>123 you're wrong" carries real text and stays, and
    a quote aimed at some other post is information the nesting doesn't convey.
    """
    covered = [False] * len(paragraph.text)
    hit_target = False
    for span in paragraph.spans:
        if not span.style or span.style[0] != "quotelink":
            continue
        _, board, _thread, post = span.style
        # Every quotelink on the line must point at an ancestor. A line that
        # also names some *other* post is carrying information the nesting
        # cannot show, so it stays whole.
        if board is not None or post not in targets:
            return False
        hit_target = True
        for i in range(max(0, span.start), min(len(paragraph.text), span.end)):
            covered[i] = True
    if not hit_target:
        return False
    for i, ch in enumerate(paragraph.text):
        if not ch.isspace() and not covered[i]:
            return False
    return True


def contains_spoiler(blocks):
    """True when any paragraph carries a spoiler span.

    The renderer uses this to decide whether a tap-to-reveal gesture belongs on
    a comment at all. Attaching one unconditionally swallows taps meant for the
    links inside the text.
    """
    for block in blocks:
        if block.kind != "paragraph":
            continue
        for span in block.spans:
            if span.style == SPOILER:
                return True
    return False
