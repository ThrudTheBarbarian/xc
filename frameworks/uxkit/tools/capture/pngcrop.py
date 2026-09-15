#!/usr/bin/env python3
# pngcrop.py — crop a rectangle out of a PNG (8-bit RGB/RGBA, non-interlaced),
# dependency-free: the capture pipeline's sub-grab knife (one contact sheet
# per platform -> ten portraits).
# usage: pngcrop.py src.png dst.png x y w h
import struct, sys, zlib

src, dst = sys.argv[1], sys.argv[2]
cx, cy, cw, ch = map(int, sys.argv[3:7])
d = open(src, "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
pos, w, h, bpp, idat = 8, 0, 0, 0, b""
while pos < len(d):
    ln, tag = struct.unpack_from(">I4s", d, pos)
    if tag == b"IHDR":
        w, h, bd, ct = struct.unpack_from(">IIBB", d, pos + 8)
        assert bd == 8 and ct in (2, 6), "unexpected PNG shape"
        bpp = 3 if ct == 2 else 4
    elif tag == b"IDAT":
        idat += d[pos + 8:pos + 8 + ln]
    pos += 12 + ln
raw = zlib.decompress(idat)
stride = w * bpp + 1

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)

out, prev = bytearray(), bytearray(w * bpp)
for y in range(h):
    ft = raw[y * stride]
    row = bytearray(raw[y * stride + 1:(y + 1) * stride])
    for x in range(len(row)):
        a = row[x - bpp] if x >= bpp else 0
        b = prev[x]
        c = prev[x - bpp] if x >= bpp else 0
        if ft == 1:   row[x] = (row[x] + a) & 255
        elif ft == 2: row[x] = (row[x] + b) & 255
        elif ft == 3: row[x] = (row[x] + (a + b) // 2) & 255
        elif ft == 4: row[x] = (row[x] + paeth(a, b, c)) & 255
    out += row
    prev = row

rows = b""
for y in range(cy, min(cy + ch, h)):
    rows += b"\x00" + bytes(out[y * w * bpp + cx * bpp: y * w * bpp + (cx + cw) * bpp])

def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", cw, ch, 8, 2 if bpp == 3 else 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))
open(dst, "wb").write(png)
