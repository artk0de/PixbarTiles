"""Throwaway: a nearest-neighbour ×3 crop of the sheet, to draw a mask by eye.

  python3 crop_sheet.py <left> <top> <right> <bottom> <out.png>
"""
import os, pickle, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
px = pickle.load(open(os.path.join(HERE, "out", "sheet.pkl"), "rb"))
l, t, r, b = map(int, sys.argv[1:5])
k = 3
rows = []
for y in range((b - t) * k):
    row = bytearray([0])
    for x in range((r - l) * k):
        row += bytes(px[t + y // k][l + x // k])
    rows.append(bytes(row))


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


w, h = (r - l) * k, (b - t) * k
open(sys.argv[5], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))
