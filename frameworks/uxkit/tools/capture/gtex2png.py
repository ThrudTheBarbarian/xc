#!/usr/bin/env python3
# gtex2png.py — the GEM theme atlas (GTEX: magic + w,h LE u32 + 0xRRGGBBAA
# rows) as a browser-loadable PNG, for the web backend's drawTheme.
# usage: gtex2png.py artwork.tex artwork.png
import struct, sys, zlib

def main(src, dst):
    d = open(src, "rb").read()
    assert d[:4] == b"GTEX", "not a GTEX atlas"
    w, h = struct.unpack_from("<II", d, 4)
    px = d[12:12 + w * h * 4]
    rows = b""
    for y in range(h):
        row = bytearray()
        for x in range(w):
            v = struct.unpack_from("<I", px, (y * w + x) * 4)[0]   # 0xRRGGBBAA
            row += bytes(((v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255))
        rows += b"\x00" + bytes(row)
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows, 9))
           + chunk(b"IEND", b""))
    open(dst, "wb").write(png)
    print(f"{src}: {w}x{h} -> {dst}")

main(sys.argv[1], sys.argv[2])
