#!/usr/bin/env python3
"""Two pictures, the same pixels? Each may be a 32-bit TGA (stored top-down
or bottom-up: run-native writes the one, chimera-run the other) or a PNG
(what Chimera's window saves). Alpha is not compared.

usage: compare-pictures.py <a> <b>   (exit 0 when the same)
"""
import struct
import sys
import zlib


def tga(d):
    w, h = struct.unpack("<HH", d[12:16])
    if d[16] != 32:
        sys.exit(f"a TGA of {d[16]} bits a pixel")
    px = d[18 + d[0]:18 + d[0] + w * h * 4]
    lines = [bytes(b for i, b in enumerate(px[y * w * 4:(y + 1) * w * 4]) if i % 4 != 3) for y in range(h)]
    if not d[17] & 0x20:
        lines.reverse()
    # BGR to RGB
    lines = [bytes(v for x in range(0, len(l), 3) for v in (l[x + 2], l[x + 1], l[x])) for l in lines]
    return w, h, lines


def png(d):
    pos, idat, w = 8, b"", 0
    while pos < len(d):
        n = struct.unpack(">I", d[pos:pos + 4])[0]
        kind, body = d[pos + 4:pos + 8], d[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or inter:
                sys.exit(f"a PNG this script does not read (depth {depth}, colour type {ctype}, interlace {inter})")
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    prev = bytearray(stride)
    lines = []
    for y in range(h):
        f = raw[y * (stride + 1)]
        cur = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = cur[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                cur[i] = (cur[i] + a) & 255
            elif f == 2:
                cur[i] = (cur[i] + b) & 255
            elif f == 3:
                cur[i] = (cur[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                cur[i] = (cur[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = cur
        lines.append(bytes(v for x in range(0, stride, bpp) for v in cur[x:x + 3]))
    return w, h, lines


def read(path):
    d = open(path, "rb").read()
    return png(d) if d[:8] == b"\x89PNG\r\n\x1a\n" else tga(d)


a, b = read(sys.argv[1]), read(sys.argv[2])
if a[:2] != b[:2]:
    sys.exit(f"sizes differ: {a[:2]} and {b[:2]}")
diff = sum(1 for x, y in zip(a[2], b[2]) if x != y)
if diff:
    sys.exit(f"{diff} of {a[1]} lines differ")
print(f"{a[0]}x{a[1]}, every pixel the same")
