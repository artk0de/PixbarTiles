"""Contact sheet of every icon's frames, as a PNG (LED-dot rendering)."""
import os, struct, zlib, sys
sys.path.insert(0, os.path.dirname(__file__))
import icons


def png(grid, path, cell=10, dot=8):
    h, w = len(grid), len(grid[0])
    bg, off = (0x0A, 0x0A, 0x0A), (0x1A, 0x1A, 0x1A)
    rows = []
    for y in range(h * cell):
        row = bytearray([0])
        for x in range(w * cell):
            gx, gy = x // cell, y // cell
            ix, iy = x - gx * cell, y - gy * cell
            c = bg
            if ix < dot and iy < dot:
                c = grid[gy][gx] or off
            row += bytes(c)
        rows.append(bytes(row))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w * cell, h * cell, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(b"".join(rows), 9)))
        f.write(chunk(b"IEND", b""))


def main():
    allicons = {**icons.THEMES, **icons.DERIVED, **icons.MOON, **icons.PAGE_ICONS}
    names = sys.argv[1:] or list(allicons)
    maxf = 8
    gap = 2
    W = maxf * (16 + gap)
    Hh = len(names) * (16 + gap)
    grid = [[None] * W for _ in range(Hh)]
    for r, n in enumerate(names):
        frames = allicons[n]()
        for i, (f, _) in enumerate(frames[:maxf]):
            for y in range(16):
                for x in range(16):
                    grid[r * 18 + y][i * 18 + x] = f[y][x]
        print(r, n, len(frames), "frames")
    png(grid, os.path.join(os.path.dirname(__file__), "sheet.png"))


main()
