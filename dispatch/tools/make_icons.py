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


def has_flat_corners(pixels, size):
    """The corners must be the flat background, or iOS's mask will cut into
    artwork that rounded itself."""
    for x, y in [(2, 2), (size - 3, 2), (2, size - 3), (size - 3, size - 3)]:
        offset = (y * size + x) * 3
        if tuple(pixels[offset:offset + 3]) != BACKGROUND:
            return False
    return True


def main():
    icon_dir = os.path.join(APP, "ios", "Dispatch", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)

    pixels = render(1024)
    if not has_flat_corners(pixels, 1024):
        raise SystemExit("FAIL: artwork is not full-bleed; iOS would mask into it")

    path = os.path.join(icon_dir, "AppIcon.png")
    size_bytes = write_png(path, 1024, 1024, pixels)
    print("AppIcon.png  1024x1024 RGB (no alpha)  %d bytes" % size_bytes)
    print("accent       #%02X%02X%02X sampled from the mark" % MARK)


if __name__ == "__main__":
    main()
