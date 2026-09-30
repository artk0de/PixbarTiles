"""A stdlib PNG reader: 8-bit RGB / RGBA, non-interlaced — enough for the mock sheet."""
import struct, zlib


def read(path):
    """→ (width, height, rows of (r, g, b))."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    i, idat, w, h, bpp = 8, b"", 0, 0, 0
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        kind, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        i += 12 + n
        if kind == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
            assert depth == 8, "8-bit only"
            bpp = {6: 4, 2: 3}[colour]
        elif kind == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    stride, rows, prev, p = w * bpp, [], bytearray(w * bpp), 0
    for _ in range(h):
        kind, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if kind == 1:
                line[x] = (line[x] + a) & 255
            elif kind == 2:
                line[x] = (line[x] + b) & 255
            elif kind == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, [[tuple(r[x * bpp:x * bpp + 3]) for x in range(w)] for r in rows]
