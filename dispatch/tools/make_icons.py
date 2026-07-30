#!/usr/bin/env python3
"""Generate Dispatch's app icon.

No image libraries are available in this environment, so the PNG encoder and
the rasteriser are both here. The mark is four stacked bars — a kicker, a heavy
headline, and two body lines — which is a shape rounded rectangles draw exactly,
with no curve fitting needed.

The bars are deliberately unequal in width. Four equal bars read as a hamburger
menu at 60pt; a short kicker over a heavy headline reads as a front page.

iOS wants 1024x1024, RGB with **no alpha channel** (an alpha channel is
rejected), and full-bleed — iOS applies its own superellipse mask, so artwork
must not carry its own rounded corners or dark wedges appear outside the mask.

Run: python3 dispatch/tools/make_icons.py
"""

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)

BACKGROUND = (0x0B, 0x0C, 0x10)
MARK = (0xF0, 0x91, 0x2B)
# The kicker is the one element allowed to differ, so the mark does not read as
# a flat stack of identical strokes.
KICKER = (0xE2, 0x5E, 0x3C)


def write_png(path, width, height, pixels):
    """pixels: flat bytearray, 3 bytes per pixel, row-major. No alpha."""
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as handle:
        handle.write(png)
    return len(png)


def rounded_rect_distance(px, py, cx, cy, half_w, half_h, radius):
    """Signed distance to a rounded rectangle: negative inside, positive out.

    The standard trick — shrink the box by the corner radius, take the distance
    to that smaller box, then subtract the radius back. Corners come out round
    without constructing any arcs.
    """
    dx = abs(px - cx) - (half_w - radius)
    dy = abs(py - cy) - (half_h - radius)
    outside = ((max(dx, 0.0)) ** 2 + (max(dy, 0.0)) ** 2) ** 0.5
    inside = min(max(dx, dy), 0.0)
    return outside + inside - radius


def render(size):
    """Four bars, centred as a group, on a flat full-bleed background."""
    pixels = bytearray(size * size * 3)

    # Every measurement is a fraction of the canvas, so the same geometry
    # rasterises at any resolution.
    left = 0.215
    bar_height = 0.082
    gap = 0.052
    radius = bar_height / 2.0

    # (width, colour). The headline is thicker than the rest; the body lines
    # are progressively shorter so the block has a ragged right edge like set
    # type rather than a justified slab.
    bars = [
        (0.300, KICKER, 0.052),
        (0.570, MARK, 0.104),
        (0.500, MARK, 0.070),
        (0.395, MARK, 0.070),
    ]

    total = sum(height for _, _, height in bars) + gap * (len(bars) - 1)
    y = 0.5 - total / 2.0

    placed = []
    for width, colour, height in bars:
        placed.append((left + width / 2.0, y + height / 2.0,
                       width / 2.0, height / 2.0, colour))
        y += height + gap

    feather = 1.2 / size

    for py_index in range(size):
        py = (py_index + 0.5) / size
        row = py_index * size * 3
        for px_index in range(size):
            px = (px_index + 0.5) / size

            # Nothing here overlaps, so the strongest coverage wins outright
            # rather than needing real alpha compositing.
            best_coverage = 0.0
            best_colour = MARK
            for cx, cy, half_w, half_h, colour in placed:
                corner = min(radius, half_h)
                distance = rounded_rect_distance(px, py, cx, cy, half_w, half_h, corner)
                if distance <= -feather:
                    coverage = 1.0
                elif distance >= feather:
                    coverage = 0.0
                else:
                    t = (distance + feather) / (2 * feather)
                    coverage = 1.0 - (t * t * (3 - 2 * t))  # smoothstep
                if coverage > best_coverage:
                    best_coverage = coverage
                    best_colour = colour
                    if coverage >= 1.0:
                        break

            offset = row + px_index * 3
            for channel in range(3):
                value = (BACKGROUND[channel]
                         + (best_colour[channel] - BACKGROUND[channel]) * best_coverage)
                pixels[offset + channel] = int(value + 0.5)

    return pixels


def has_flat_corners(pixels, size, ground=BACKGROUND):
    """The corners must be the flat background, or iOS's mask will cut into
    artwork that rounded itself.

    Checked against whatever the artwork's own ground is, since a supplied image
    brings its own. A resample can move a corner byte by one, so this allows a
    hair of tolerance rather than demanding an exact match.
    """
    for x, y in [(2, 2), (size - 3, 2), (2, size - 3), (size - 3, size - 3)]:
        offset = (y * size + x) * 3
        for channel in range(3):
            if abs(pixels[offset + channel] - ground[channel]) > 2:
                return False
    return True


# --- Reading a supplied image -----------------------------------------------
#
# There are no image libraries here, so the PNG decoder is also in this file.
# Only what a real export produces is handled — 8-bit, non-interlaced, RGB or
# RGBA — and anything else fails loudly rather than writing a corrupt icon.


def read_png(path):
    """Returns (width, height, RGB bytearray). Raises on anything unexpected."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("FAIL: %s is not a PNG" % path)

    width = height = 0
    channels = 3
    idat = bytearray()
    offset = 8
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        tag = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        if tag == b"IHDR":
            width, height, depth, colour, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8:
                raise SystemExit("FAIL: %d-bit PNG; only 8-bit is handled" % depth)
            if interlace:
                raise SystemExit("FAIL: interlaced PNG; re-export without interlacing")
            if colour == 2:
                channels = 3
            elif colour == 6:
                channels = 4
            else:
                raise SystemExit("FAIL: colour type %d; export RGB or RGBA" % colour)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        offset += 12 + length

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * 3)
    previous = bytearray(stride)
    position = 0

    for y in range(height):
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride

        # Unfilter in place. The four cases are the PNG spec's, and getting
        # Paeth wrong produces an image that is recognisable but streaked, which
        # is the kind of bug that survives a glance.
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                upleft = previous[i - channels] if i >= channels else 0
                estimate = left + up - upleft
                pa, pb, pc = abs(estimate - left), abs(estimate - up), abs(estimate - upleft)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = upleft
                line[i] = (line[i] + predictor) & 0xFF
        elif filter_type != 0:
            raise SystemExit("FAIL: unknown PNG filter %d" % filter_type)

        for x in range(width):
            source = x * channels
            target = (y * width + x) * 3
            out[target:target + 3] = line[source:source + 3]

        previous = line

    return width, height, out


def luminance(pixels, index):
    r, g, b = pixels[index], pixels[index + 1], pixels[index + 2]
    return (r * 299 + g * 587 + b * 114) // 1000


# Anything this bright is the page the artwork was exported onto, not the
# artwork. The supplied mark's lightest element is a mid grey, so there is a
# wide margin here.
PAGE_THRESHOLD = 200


def content_box(pixels, width, height):
    """The bounds of everything that is not the exported page."""
    left, top, right, bottom = width, height, -1, -1
    for y in range(height):
        row = y * width
        for x in range(width):
            if luminance(pixels, (row + x) * 3) <= PAGE_THRESHOLD:
                if x < left:
                    left = x
                if x > right:
                    right = x
                if y < top:
                    top = y
                if y > bottom:
                    bottom = y
    if right < 0:
        raise SystemExit("FAIL: the source image is blank")
    return left, top, right, bottom


def flatten_to_ground(pixels, width, height, ground):
    """Makes everything that is not the mark exactly the artwork's own ground.

    iOS applies its own superellipse mask, so an image that rounds its own corners
    and sits on white keeps that white *outside* its curve and inside Apple's:
    four pale wedges around a dark square. Going full-bleed in the artwork's own
    background colour means Apple's mask cuts into flat colour.

    Two passes, because one is not enough on real artwork and each pass exists for
    a failure this went through:

    **A flood fill inward from the border**, through anything that is not the
    ground colour. That is what removes the page and — the part a brightness
    threshold missed — the soft ring where the artwork's curve meets it. That ring
    is lighter than everything in the mark, so left behind it won any "brightest
    colour here" question and became the app's tint, sampled from an
    anti-aliasing artifact.

    **Then a floor: nothing may be darker than the ground.** The fill alone cannot
    reach a drop shadow, because a shadow fades *through* the ground value on its
    way out to the page — so the fill meets a ring of ground-coloured pixels and
    stops with the dark core still behind it, leaving a band along one edge that
    the contrast lift turns into speckle. The floor catches it wherever it is. It
    also flattens the mark's own dark details — the rules and the photo block cut
    into the paper — onto exactly the ground, which is what they already looked
    like against a near-black field.
    """
    ground_luminance = luminance(bytes(ground), 0)
    visited = bytearray(width * height)
    stack = []

    def consider(x, y):
        position = y * width + x
        if visited[position]:
            return
        if abs(luminance(pixels, position * 3) - ground_luminance) <= GRAIN:
            return
        visited[position] = 1
        stack.append(position)

    for x in range(width):
        consider(x, 0)
        consider(x, height - 1)
    for y in range(height):
        consider(0, y)
        consider(width - 1, y)

    outside = 0
    while stack:
        position = stack.pop()
        pixels[position * 3:position * 3 + 3] = bytes(ground)
        outside += 1
        x, y = position % width, position // width
        if x > 0:
            consider(x - 1, y)
        if x + 1 < width:
            consider(x + 1, y)
        if y > 0:
            consider(x, y - 1)
        if y + 1 < height:
            consider(x, y + 1)

    floored = 0
    for index in range(0, width * height * 3, 3):
        if luminance(pixels, index) < ground_luminance:
            pixels[index:index + 3] = bytes(ground)
            floored += 1

    return outside, floored


def resample(pixels, width, height, size):
    """Box-average downscale. Correct for shrinking and cheap to be sure of."""
    out = bytearray(size * size * 3)
    for ty in range(size):
        y0 = ty * height // size
        y1 = max(y0 + 1, (ty + 1) * height // size)
        for tx in range(size):
            x0 = tx * width // size
            x1 = max(x0 + 1, (tx + 1) * width // size)
            totals = [0, 0, 0]
            count = 0
            for y in range(y0, y1):
                row = y * width
                for x in range(x0, x1):
                    index = (row + x) * 3
                    totals[0] += pixels[index]
                    totals[1] += pixels[index + 1]
                    totals[2] += pixels[index + 2]
                    count += 1
            target = (ty * size + tx) * 3
            for channel in range(3):
                out[target + channel] = totals[channel] // count
    return out


def crop(pixels, width, box):
    left, top, right, bottom = box
    new_width = right - left + 1
    new_height = bottom - top + 1
    out = bytearray(new_width * new_height * 3)
    for y in range(new_height):
        source = ((y + top) * width + left) * 3
        target = y * new_width * 3
        out[target:target + new_width * 3] = pixels[source:source + new_width * 3]
    return new_width, new_height, out


def lift(pixels, width, height, ground, factor):
    """Pushes the mark away from its background without moving the background.

    The supplied artwork is a dark grey mark on a near-black ground, which is
    handsome at full size and a black square at 60 points. This scales each
    pixel's distance from the ground colour, so the ground stays exactly flat —
    important, because iOS masks into it — and everything drawn on top gains
    contrast.
    """
    ground_luminance = luminance(bytes(ground), 0)
    for index in range(0, width * height * 3, 3):
        # A deadzone around the ground. Without it the export's grain — a few
        # values either side of flat — is amplified along with the mark, and the
        # field goes blotchy. Snapping it to exactly the ground also means the
        # corners iOS masks into are truly flat.
        if abs(luminance(pixels, index) - ground_luminance) <= GRAIN:
            pixels[index:index + 3] = bytes(ground)
            continue
        for channel in range(3):
            base = ground[channel]
            value = pixels[index + channel]
            scaled = base + (value - base) * factor
            pixels[index + channel] = max(0, min(255, int(scaled + 0.5)))
    return pixels


SOURCE = os.path.join(APP, "design", "icon-source.png")

# How far the supplied mark is pushed away from its own background. 1.0 is the
# artwork untouched; this is the value that makes it legible at 60 points without
# turning the mark white.
LIFT = 2.5

# How far from the ground still counts as the ground. A real export is not flat;
# this is the width of that noise.
GRAIN = 7


def from_source(path, size=1024, factor=LIFT):
    """Turns a supplied square export into a full-bleed iOS icon."""
    width, height, pixels = read_png(path)

    box = content_box(pixels, width, height)
    width, height, pixels = crop(pixels, width, box)

    ground = dominant(pixels, width, height)

    outside, floored = flatten_to_ground(pixels, width, height, ground)

    # Sampled before the lift. Afterwards the brightest pixel is wherever the
    # scaling clamped, which is pure white and tells you nothing about the
    # artwork.
    natural_accent = brightest(pixels, width, height)

    if factor != 1.0:
        lift(pixels, width, height, ground, factor)

    # Non-square exports are padded rather than stretched, because stretching a
    # logo is never the right answer and silently doing it is worse.
    if width != height:
        original = (width, height)
        side = max(width, height)
        square = bytearray(side * side * 3)
        for index in range(0, side * side * 3, 3):
            square[index:index + 3] = bytes(ground)
        offset_x = (side - width) // 2
        offset_y = (side - height) // 2
        for y in range(height):
            source = y * width * 3
            target = ((y + offset_y) * side + offset_x) * 3
            square[target:target + width * 3] = pixels[source:source + width * 3]
        width = height = side
        pixels = square
        print("source cropped to %dx%d; padded square with the ground colour" % original)

    print("flattened     %d px outside the mark, %d px darker than the ground"
          % (outside, floored))
    return resample(pixels, width, height, size), ground, natural_accent


def main():
    icon_dir = os.path.join(APP, "ios", "Dispatch", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)

    if os.path.exists(SOURCE):
        pixels, ground, accent = from_source(SOURCE)
        origin = "design/icon-source.png"
    else:
        pixels = render(1024)
        ground, accent = BACKGROUND, MARK
        origin = "the generated mark"

    if not has_flat_corners(pixels, 1024, ground):
        raise SystemExit("FAIL: artwork is not full-bleed; iOS would mask into it")

    path = os.path.join(icon_dir, "AppIcon.png")
    size_bytes = write_png(path, 1024, 1024, pixels)
    print("AppIcon.png  1024x1024 RGB (no alpha)  %d bytes  from %s" % (size_bytes, origin))

    write_android_icons(pixels)
    print("ground       #%02X%02X%02X" % ground)
    if luminance(bytes(accent), 0) < 140:
        print("accent       #%02X%02X%02X is the artwork's lightest colour, too dark to tint"
              % accent)
        print("             with — Palette.accent uses the neutral #%02X%02X%02X instead"
              % NEUTRAL_TINT)
    else:
        print("accent       #%02X%02X%02X  (Palette.accent should match)" % accent)


def dominant(pixels, width, height):
    """The artwork's own background, as the colour that covers the most of it.

    Sampling a pixel near an edge is what this replaces, and the failure was
    visible: the top edge of a rounded square is its anti-aliased boundary, not
    its fill, so the page got flooded with a colour a few values off the real
    one and the join showed as a faint rounded outline — then the contrast lift
    multiplied that difference by two and a half.

    Counted in coarse buckets because a real export has grain in it: quantising
    groups a thousand near-identical darks into one bucket, and the average
    within the winning bucket is the colour itself.
    """
    counts = {}
    for index in range(0, width * height * 3, 3):
        bucket = (pixels[index] >> 3, pixels[index + 1] >> 3, pixels[index + 2] >> 3)
        counts[bucket] = counts.get(bucket, 0) + 1
    winner = max(counts, key=counts.get)

    totals = [0, 0, 0]
    count = 0
    for index in range(0, width * height * 3, 3):
        if (pixels[index] >> 3, pixels[index + 1] >> 3, pixels[index + 2] >> 3) == winner:
            for channel in range(3):
                totals[channel] += pixels[index + channel]
            count += 1
    return tuple(total // count for total in totals)


# Android wants the launcher icon at five densities. Same artwork, resampled
# from the same 1024 master, so the two apps cannot end up with different icons
# because someone exported twice.
ANDROID_DENSITIES = [
    ("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192),
]


def write_android_icons(master):
    root = os.path.join(APP, "android", "app", "src", "main", "res")
    if not os.path.isdir(os.path.dirname(root)):
        return

    total = 0
    for name, size in ANDROID_DENSITIES:
        directory = os.path.join(root, "mipmap-" + name)
        os.makedirs(directory, exist_ok=True)
        scaled = resample(master, 1024, 1024, size)
        total += write_png(os.path.join(directory, "ic_launcher.png"), size, size, scaled)
    print("ic_launcher   %d densities, %d bytes total" % (len(ANDROID_DENSITIES), total))


def brightest(pixels, width, height):
    """The lightest colour in the artwork."""
    best = (0, 0, 0)
    best_luminance = -1
    for index in range(0, width * height * 3, 3):
        value = luminance(pixels, index)
        if value > best_luminance:
            best_luminance = value
            best = (pixels[index], pixels[index + 1], pixels[index + 2])
    return best


# What the app tints with when the artwork has no colour bright enough to tint
# with. A monochrome icon has no accent in it, and a dark grey button is not a
# button — so the app goes neutral and lets the four section colours be the only
# colour in it.
NEUTRAL_TINT = (0xE6, 0xE8, 0xEC)


if __name__ == "__main__":
    main()
