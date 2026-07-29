#!/usr/bin/env python3
"""Generate app icons for both platforms from one procedural source.

No image libraries are available in this environment, so the PNG encoder and
the rasteriser are both here. That is less of a compromise than it sounds: the
mark is a chevron, which is two thick line segments, and drawing it by distance
field gives cleaner antialiasing than scaling a bitmap would.

The mark is a '>' — the greentext prompt, which is the most recognisable piece
of visual grammar the board has.

The two platforms want opposite things from the same artwork:

  iOS      1024x1024, RGB with **no alpha channel** (an alpha channel is
           rejected at submission), and full-bleed — iOS applies its own
           superellipse mask, so artwork must not carry its own rounded
           corners or dark wedges appear outside the mask.

  Android  adaptive icon: a solid background layer plus a **transparent**
           foreground PNG. The safe zone is the centre ~66%, so the glyph is
           drawn smaller relative to the canvas than on iOS.

Run: python3 tools/make_icons.py
"""

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Sampled from the mark itself rather than guessed at: these are the exact
# values the accent colour and the Android background layer are set from.
BACKGROUND = (0x12, 0x16, 0x1A)
CHEVRON = (0x8C, 0xB3, 0x3F)


def write_png(path, width, height, pixels, has_alpha):
    """pixels: flat bytearray, 3 or 4 bytes per pixel, row-major."""
    channels = 4 if has_alpha else 3
    color_type = 6 if has_alpha else 2
    stride = width * channels

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
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
    t = ((px - ax) * dx + (py - ay) * dy) / length_sq
    t = max(0.0, min(1.0, t))
    cx, cy = ax + t * dx, ay + t * dy
    return ((px - cx) ** 2 + (py - cy) ** 2) ** 0.5


def render(size, glyph_scale, has_alpha):
    """Rasterise the chevron centred on the canvas.

    `glyph_scale` is the fraction of the canvas the mark spans, which is what
    differs between the two platforms: iOS is full-bleed, Android must stay
    inside the centre safe zone.
    """
    channels = 4 if has_alpha else 3
    pixels = bytearray(size * size * channels)

    half = glyph_scale / 2.0
    # Chevron vertices in unit space, centred on (0.5, 0.5). Nudged right so
    # the mark is optically centred: a '>' has more mass on its left.
    cx, cy = 0.5 - half * 0.08, 0.5
    ax, ay = cx - half * 0.55, cy - half * 0.80
    bx, by = cx + half * 0.62, cy
    dx, dy = cx - half * 0.55, cy + half * 0.80

    thickness = glyph_scale * 0.115
    # Antialias across roughly one and a half pixels.
    feather = 1.5 / size

    for y in range(size):
        py = (y + 0.5) / size
        row = y * size * channels
        for x in range(size):
            px = (x + 0.5) / size
            distance = min(
                distance_to_segment(px, py, ax, ay, bx, by),
                distance_to_segment(px, py, bx, by, dx, dy),
            )
            edge = distance - thickness / 2.0
            if edge <= -feather:
                coverage = 1.0
            elif edge >= feather:
                coverage = 0.0
            else:
                t = (edge + feather) / (2 * feather)
                coverage = 1.0 - (t * t * (3 - 2 * t))  # smoothstep

            offset = row + x * channels
            if has_alpha:
                # Transparent foreground layer: the glyph colour is constant and
                # coverage lives entirely in the alpha channel, which keeps the
                # antialiased edge clean over any background Android composites
                # underneath it.
                pixels[offset] = CHEVRON[0]
                pixels[offset + 1] = CHEVRON[1]
                pixels[offset + 2] = CHEVRON[2]
                pixels[offset + 3] = int(coverage * 255 + 0.5)
            else:
                for channel in range(3):
                    value = BACKGROUND[channel] + (CHEVRON[channel] - BACKGROUND[channel]) * coverage
                    pixels[offset + channel] = int(value + 0.5)
    return pixels


def glyph_bounds(pixels, size, channels):
    """Bounding box of visible glyph pixels, as fractions of the canvas.

    Used to assert the Android mark actually fits the safe zone rather than
    assuming the arithmetic above was right.
    """
    min_x, min_y, max_x, max_y = size, size, -1, -1
    for y in range(size):
        for x in range(size):
            offset = (y * size + x) * channels
            visible = pixels[offset + 3] > 8 if channels == 4 else (
                abs(pixels[offset] - BACKGROUND[0]) > 8
            )
            if visible:
                min_x, max_x = min(min_x, x), max(max_x, x)
                min_y, max_y = min(min_y, y), max(max_y, y)
    if max_x < 0:
        return None
    return (min_x / size, min_y / size, (max_x + 1) / size, (max_y + 1) / size)


def main():
    ios_dir = os.path.join(REPO, "ios", "PolReader", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(ios_dir, exist_ok=True)

    # Full-bleed: iOS masks the corners itself.
    ios_pixels = render(1024, glyph_scale=0.62, has_alpha=False)
    ios_path = os.path.join(ios_dir, "AppIcon.png")
    size_bytes = write_png(ios_path, 1024, 1024, ios_pixels, has_alpha=False)
    print("ios   AppIcon.png       1024x1024 RGB   %7d bytes" % size_bytes)

    android_dir = os.path.join(REPO, "android", "app", "src", "main", "res", "drawable")
    os.makedirs(android_dir, exist_ok=True)

    # Smaller mark: anything outside the centre ~66% can be masked away.
    android_pixels = render(432, glyph_scale=0.42, has_alpha=True)
    android_path = os.path.join(android_dir, "ic_launcher_foreground.png")
    size_bytes = write_png(android_path, 432, 432, android_pixels, has_alpha=True)
    print("android foreground     432x432 RGBA   %7d bytes" % size_bytes)

    bounds = glyph_bounds(android_pixels, 432, 4)
    if bounds:
        left, top, right, bottom = bounds
        print("        glyph bounds       x %.3f-%.3f  y %.3f-%.3f" % (left, right, top, bottom))
        # The safe zone is the centre 66%, i.e. 0.17 to 0.83.
        if left < 0.17 or top < 0.17 or right > 0.83 or bottom > 0.83:
            raise SystemExit("FAIL: Android glyph leaves the centre safe zone and would be masked")
        print("        safe zone          ok (within 0.17-0.83)")

    accent = os.path.join(REPO, "ios", "PolReader", "Assets.xcassets", "AccentColor.colorset")
    print("accent  #%02X%02X%02X sampled from the mark" % CHEVRON)
    if not os.path.isdir(accent):
        print("        (AccentColor.colorset not present yet)")


if __name__ == "__main__":
    main()
