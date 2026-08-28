#!/usr/bin/env python3
"""Generate Macro's app icon.

No image libraries are available in this environment, so the PNG encoder and
the rasteriser are both here. The mark is a rising price line with round caps —
exactly the kind of shape a distance field draws better than a scaled bitmap
would.

iOS wants 1024x1024, RGB with **no alpha channel** (an alpha channel is
rejected), and full-bleed — iOS applies its own superellipse mask, so artwork
must not carry its own rounded corners or dark wedges appear outside the mask.

Run: python3 macro/tools/make_icons.py
"""

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)

BACKGROUND = (0x0A, 0x12, 0x1E)   # deep navy
MARK = (0x2E, 0xD1, 0x6E)         # market green — matches AccentColor


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


def distance_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy
    if length_sq == 0:
        return ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_sq))
    cx, cy = ax + t * dx, ay + t * dy
    return ((px - cx) ** 2 + (py - cy) ** 2) ** 0.5


# The polyline: a market that dips, recovers, and rips. Chosen so the mass
# sits centred and the last leg dominates. y grows downward.
POLYLINE = [
    (0.18, 0.66),
    (0.36, 0.50),
    (0.48, 0.60),
    (0.82, 0.28),
]

STROKE = 0.055   # half-width of the line, in icon fractions
DOT_RADIUS = 0.075


def render(size):
    """The polyline as a distance field: every point within STROKE of any
    segment is the mark, which gives round joins and caps for free. A filled
    dot punctuates the final print."""
    pixels = bytearray(size * size * 3)
    segments = list(zip(POLYLINE, POLYLINE[1:]))
    dot = POLYLINE[-1]
    feather = 1.5 / size

    for y in range(size):
        py = (y + 0.5) / size
        row = y * size * 3
        for x in range(size):
            px = (x + 0.5) / size

            line_distance = min(
                distance_to_segment(px, py, a[0], a[1], b[0], b[1])
                for a, b in segments
            )
            dot_distance = ((px - dot[0]) ** 2 + (py - dot[1]) ** 2) ** 0.5

            edge = min(line_distance - STROKE, dot_distance - DOT_RADIUS)
            if edge <= -feather:
                coverage = 1.0
            elif edge >= feather:
                coverage = 0.0
            else:
                t = (edge + feather) / (2 * feather)
                coverage = 1.0 - (t * t * (3 - 2 * t))  # smoothstep

            offset = row + x * 3
            for channel in range(3):
                value = BACKGROUND[channel] + (MARK[channel] - BACKGROUND[channel]) * coverage
                pixels[offset + channel] = int(value + 0.5)

    return pixels


def has_clean_corners(pixels, size):
    """The corners must be the flat background, or iOS's mask will cut into
    artwork that rounded itself."""
    for x, y in [(2, 2), (size - 3, 2), (2, size - 3), (size - 3, size - 3)]:
        offset = (y * size + x) * 3
        if tuple(pixels[offset:offset + 3]) != BACKGROUND:
            return False
    return True


def main():
    icon_dir = os.path.join(APP, "ios", "Macro", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)

    pixels = render(1024)
    if not has_clean_corners(pixels, 1024):
        raise SystemExit("FAIL: artwork is not full-bleed; iOS would mask into it")

    path = os.path.join(icon_dir, "AppIcon.png")
    size_bytes = write_png(path, 1024, 1024, pixels)
    print("AppIcon.png  1024x1024 RGB (no alpha)  %d bytes" % size_bytes)
    print("accent       #%02X%02X%02X sampled from the mark" % MARK)


if __name__ == "__main__":
    main()
