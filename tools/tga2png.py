#!/usr/bin/env python3
"""Converts the test harness's uncompressed 32-bit TGA pictures to PNG, with
nothing but the standard library. usage: tools/tga2png.py in.tga out.png"""
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
idlen, cmtype, itype = d[0], d[1], d[2]
w, h, bpp, desc = struct.unpack_from("<HHBB", d, 12)
assert itype == 2 and bpp == 32, (itype, bpp)
px = d[18 + idlen:]
rows = [px[y * w * 4:(y + 1) * w * 4] for y in range(h)]
if not desc & 0x20:  # bottom-up
    rows.reverse()
raw = b"".join(b"\0" + bytes(r[i + 2 - (i % 4) * 2 if i % 4 < 3 else i] for i in range(len(r))) for r in rows)
def chunk(t, b):
    return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
