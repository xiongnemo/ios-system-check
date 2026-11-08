#!/usr/bin/env python3
"""The icon of SystemCheck as the PNGs its Info.plist names (no asset catalog: actool is a Mac program): four tiles
on a graphite to steel-blue gradient, one per kind of check -- an orange one with a chip (the GPU), a slate one with a
cube (Metal), a red one with a play sign (video), a green one with a signal (the sensors) -- tied together by a teal
disc in a white ring with a white check mark where their corners meet. SpringBoard rounds the corners itself.
usage: python3 -I mkicon.py APP_DIR"""
import math
import os
import struct
import sys
import zlib

TOP, BOTTOM = (0x16, 0x1a, 0x22), (0x2a, 0x3a, 0x52)
WHITE = (0xff, 0xff, 0xff)
TEAL = (0x1f, 0xb5, 0xc4)
TILE, GAP, CORNER = 0.36, 0.06, 0.07             # the tiles: side, the gap between them, their corners' radius
TILES = (  # each: its centre, its colour at the top and at the bottom, its sign
    ((0.29, 0.29), (0xf5, 0x9a, 0x3c), (0xd9, 0x68, 0x1a), 'chip'),
    ((0.71, 0.29), (0x8f, 0x9b, 0xad), (0x5d, 0x68, 0x78), 'cube'),
    ((0.29, 0.71), (0xec, 0x55, 0x5a), (0xc2, 0x2f, 0x35), 'play'),
    ((0.71, 0.71), (0x3a, 0xc9, 0x80), (0x1f, 0x9a, 0x5a), 'signal'),
)
BADGE = (0.5, 0.5, 0.112)                        # the check's disc: centre and radius
RING = 0.022
CHECK = ((-0.050, 0.004), (-0.014, 0.040), (0.054, -0.034))
STROKE = 0.021
SS = 4      # samples per pixel along each side


def mix(c, d, a):
    return tuple(x + (y - x) * a for x, y in zip(c, d))


def in_rounded(u, v, cx, cy, half, r):
    dx, dy = max(abs(u - cx) - (half - r), 0.0), max(abs(v - cy) - (half - r), 0.0)
    return abs(u - cx) <= half and abs(v - cy) <= half and dx * dx + dy * dy <= r * r


def in_polygon(u, v, corners):
    """in a convex polygon whose corners go round one way"""
    sign = 0
    for (x1, y1), (x2, y2) in zip(corners, corners[1:] + corners[:1]):
        cross = (x2 - x1) * (v - y1) - (y2 - y1) * (u - x1)
        if cross != 0:
            if sign == 0:
                sign = 1 if cross > 0 else -1
            elif (cross > 0) != (sign > 0):
                return False
    return True


def segment(u, v, p, q):
    (px, py), (qx, qy) = p, q
    dx, dy = qx - px, qy - py
    t = max(0.0, min(1.0, ((u - px) * dx + (v - py) * dy) / (dx * dx + dy * dy)))
    return math.hypot(u - px - t * dx, v - py - t * dy)


def sign(kind, x, y, c, tile):
    """the tile's sign, at (x, y) from the tile's centre: the colour there, or c"""
    if kind == 'chip':
        # a white body with a die of the tile's colour, three pins a side
        if in_rounded(x, y, 0, 0, 0.072, 0.014):
            return tile if in_rounded(x, y, 0, 0, 0.034, 0.006) else WHITE
        for k in (-0.040, 0.0, 0.040):
            for px, py in ((k, 0.091), (k, -0.091), (0.091, k), (-0.091, k)):
                if abs(x - px) <= (0.009 if abs(py) > abs(px) else 0.019) and \
                        abs(y - py) <= (0.019 if abs(py) > abs(px) else 0.009):
                    return WHITE
        return c
    if kind == 'cube':
        t, r, m, l = (0, -0.088), (0.077, -0.044), (0, 0), (-0.077, -0.044)
        br, b, bl = (0.077, 0.044), (0, 0.088), (-0.077, 0.044)
        for corners, shade in (((t, r, m, l), WHITE), ((l, m, b, bl), (0xd5, 0xdb, 0xe3)),
                               ((m, r, br, b), (0xa3, 0xad, 0xbb))):
            if in_polygon(x, y, corners):
                return shade
        return c
    if kind == 'play':
        return WHITE if in_polygon(x, y, ((-0.040, -0.062), (0.066, 0.0), (-0.040, 0.062))) else c
    # signal: a dot at the lower left, three quarter rings around it toward the upper right
    dx, dy = x + 0.055, y - 0.055
    d = math.hypot(dx, dy)
    if d <= 0.022:
        return WHITE
    if dx >= -0.004 and dy <= 0.004:
        for radius in (0.052, 0.090, 0.128):
            if abs(d - radius) <= 0.0105:
                return WHITE
    return c


def color(u, v, bg):
    c = bg
    for (cx, cy), high, low, kind in TILES:
        half = TILE / 2
        if in_rounded(u + 0.012, v - 0.012, cx, cy, half, CORNER):
            c = mix(c, (0, 0, 0), 0.30)           # a soft shadow below and to the left
        if in_rounded(u, v, cx, cy, half, CORNER):
            tile = mix(high, low, (v - (cy - half)) / TILE)
            c = sign(kind, u - cx, v - cy, tile, tile)
    bx, by, br = BADGE
    r = math.hypot(u - bx, v - by)
    if r < br + RING:
        c = WHITE
    if r < br:
        c = TEAL
        p = [(bx + x, by + y) for x, y in CHECK]
        if min(segment(u, v, p[0], p[1]), segment(u, v, p[1], p[2])) < STROKE:
            c = WHITE
    return c


def png(size):
    rows = []
    for y in range(size):
        row = bytearray([0])
        bg = [a + (b - a) * y / (size - 1) for a, b in zip(TOP, BOTTOM)]
        for x in range(size):
            total = [0, 0, 0]
            for i in range(SS):
                for j in range(SS):
                    c = color((x + (i + 0.5) / SS) / size, (y + (j + 0.5) / SS) / size, bg)
                    total = [t + k for t, k in zip(total, c)]
            row += bytes(min(255, round(t / (SS * SS))) for t in total)
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for scale in (2, 3):
        with open(os.path.join(sys.argv[1], 'AppIcon60x60@%dx.png' % scale), 'wb') as f:
            f.write(png(60 * scale))


main()
