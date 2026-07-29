#!/usr/bin/env python3
"""Generate Vela's app icon.

No image libraries are available in this environment, so the PNG encoder and the
rasteriser are both here. That is less of a compromise than it sounds: the mark
is a rounded play triangle, which is exactly the kind of shape a distance field
draws better than a scaled bitmap would.

iOS wants 1024x1024, RGB with **no alpha channel** (an alpha channel is
rejected), and full-bleed — iOS applies its own superellipse mask, so artwork
must not carry its own rounded corners or dark wedges appear outside the mask.

Run: python3 vela/tools/make_icons.py
"""

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)

BACKGROUND = (0x0C, 0x0C, 0x0E)
MARK = (0xE0, 0x32, 0x2F)


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


def inside_triangle(px, py, tri):
    """Winding test. Consistent sign across all three edges means inside."""
    (ax, ay), (bx, by), (cx, cy) = tri
    d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by)
    d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy)
    d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay)
    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (has_neg and has_pos)


def render(size, scale, corner):
    """A play triangle with rounded corners.

    Drawn as "every point within `corner` of an inset triangle", which rounds
    the corners evenly without needing to construct arc geometry.
    """
    pixels = bytearray(size * size * 3)

    # Optically centred rather than geometrically: a triangle pointing right
    # has its mass to the left, so the bounding box is nudged right.
    cx, cy = 0.5 + scale * 0.04, 0.5
    half = scale / 2.0
    tri = [
        (cx - half * 0.62, cy - half * 0.86),
        (cx + half * 0.80, cy),
        (cx - half * 0.62, cy + half * 0.86),
    ]

    # Shrink toward the centroid so the rounded result lands back on the
    # intended silhouette rather than growing past it.
    gx = sum(p[0] for p in tri) / 3.0
    gy = sum(p[1] for p in tri) / 3.0
    inset = [(gx + (x - gx) * (1 - corner * 2.2), gy + (y - gy) * (1 - corner * 2.2))
             for x, y in tri]

    feather = 1.5 / size

    for y in range(size):
        py = (y + 0.5) / size
        row = y * size * 3
        for x in range(size):
            px = (x + 0.5) / size

            if inside_triangle(px, py, inset):
                distance = 0.0
            else:
                distance = min(
                    distance_to_segment(px, py, *inset[0], *inset[1]),
                    distance_to_segment(px, py, *inset[1], *inset[2]),
                    distance_to_segment(px, py, *inset[2], *inset[0]),
                )

            edge = distance - corner
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


def has_alpha_free_corners(pixels, size):
    """The corners must be the flat background, or iOS's mask will cut into
    artwork that rounded itself."""
    for x, y in [(2, 2), (size - 3, 2), (2, size - 3), (size - 3, size - 3)]:
        offset = (y * size + x) * 3
        if tuple(pixels[offset:offset + 3]) != BACKGROUND:
            return False
    return True


def main():
    icon_dir = os.path.join(APP, "ios", "Vela", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)

    pixels = render(1024, scale=0.52, corner=0.035)
    if not has_alpha_free_corners(pixels, 1024):
        raise SystemExit("FAIL: artwork is not full-bleed; iOS would mask into it")

    path = os.path.join(icon_dir, "AppIcon.png")
    size_bytes = write_png(path, 1024, 1024, pixels)
    print("AppIcon.png  1024x1024 RGB (no alpha)  %d bytes" % size_bytes)
    print("accent       #%02X%02X%02X sampled from the mark" % MARK)


if __name__ == "__main__":
    main()
