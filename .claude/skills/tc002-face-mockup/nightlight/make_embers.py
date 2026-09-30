"""Offline helper: the ember bed literal for `embers.py`. Coal lumps of
random width and height on the bottom rows; each lump a dark crust over a
glowing core, the seams between lumps glowing hotter, a few hot spots low
down. Prints the rows; `embers.BED` is a hand-checked copy.

Heat digits 1…8 name `embers.HEAT`; '.' is empty."""
import sys

W, ROWS = 52, 6


class LCG:
    def __init__(self, seed):
        self.s = seed

    def next(self, n):
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.s >> 8) % n


def build(seed=0xE3B):
    r = LCG(seed)
    height = [0] * W
    seam = [False] * W
    x = 0
    while x < W:
        w, h = 3 + r.next(5), 2 + r.next(4)
        for dx in range(w):
            if x + dx < W:
                edge = dx in (0, w - 1)
                height[x + dx] = max(1, h - (1 if edge and r.next(2) else 0))
        if x + w < W:
            seam[x + w - 1] = True
        x += w
    rows = [["."] * W for _ in range(ROWS)]
    for x in range(W):
        top = ROWS - height[x]
        for y in range(top, ROWS):
            d = y - top                              # depth under the crust
            low = ROWS - 1 - y                       # rows above the bottom
            heat = 1 if d == 0 else 2 + (d >= 2) + (low == 0)
            if seam[x] and d >= 1:
                heat += 2
            if r.next(9) == 0:
                heat += 1
            rows[y][x] = str(max(1, min(8, heat)))
    for _ in range(5):                               # hot spots on the bottom two rows
        x, y = 2 + r.next(W - 4), ROWS - 1 - r.next(2)
        if rows[y][x] != ".":
            rows[y][x] = "8"
            for dx in (-1, 1):
                if rows[y][x + dx] != ".":
                    rows[y][x + dx] = str(max(int(rows[y][x + dx]), 6))
    return ["".join(row) for row in rows]


if __name__ == "__main__":
    seed = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0xE3B
    for row in build(seed):
        print(f'    "{row}",')
