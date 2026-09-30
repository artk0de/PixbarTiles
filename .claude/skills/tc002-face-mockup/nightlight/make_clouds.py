"""Offline helper: the Red Moon cloud bank as a character mask, cell for cell
from the sheet's native grid (`out/native-moon.json`, 57×13).

The sheet's rows 8…12 land on rows 11…15 (same cell height, bottom-aligned);
its 57 columns are resampled to 52 by nearest column. A cell's red level
becomes an ink of 4 red per step ('2' = 8 … 'G' = 64), so each billow keeps
the sheet's own ramp. Cleaned on the way: the moon's bloom baked into the
cells right under the crescent is capped to body level (the scene's
moonlight lights that edge live); holes inside the silhouette are filled from
their neighbours; the field is smoothed once with a 3×3 kernel inside the
silhouette; specks and stray cells are dropped; two corner cells that stand
as vertical sides are taken off so nothing reads as a box. A crest step is
put on top of the mound so it can pass under the horn; the mound gets a left
shoulder across the wrap (the sheet's edge had cut it); the band's tail and
the shoulder's foot are drawn out a few columns in the same inks, fading,
so the one dip between them is narrow.

  python3 make_clouds.py     # prints FRONT for redmoon.py
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
INKS = "..23456789ABCDEFG"          # index = red // 4
W, SHEET_ROW0, OUR_ROW0, ROWS = 52, 8, 11, 5
FLOOR = 6                           # below this a cell is off
BLOOM_COLS, BLOOM_ROWS, BLOOM_CAP = range(2, 13), (8, 9), 24
SHEET_STARS = {(8, 22)}             # a star of the sheet inside the cloud rows
MIN_BLOB = 6                        # smaller islands are specks
CREST_STEP = [40, 28, 20]           # the added top of the mound, x 0…2 on row 10
CORNERS = {(34, 14), (48, 13)}      # cells taken off to round a vertical side
# The mound's left shoulder, across the wrap (the sheet's edge cut it off):
# one row per column up to the crest at x 0, dimmer at its foot; it takes
# in the sheet's far wisp. (x, y) → red.
SHOULDER = {
    (51, 11): 36, (51, 12): 32, (51, 13): 24, (51, 14): 20, (51, 15): 16,
    (50, 12): 24, (50, 13): 20, (50, 14): 16, (50, 15): 12,
    (49, 13): 16, (49, 14): 16, (49, 15): 12,
    (48, 14): 12, (48, 15): 12,
    (47, 15): 12,
}
# The band's tail drawn out to the right and the shoulder's foot to the
# left, fading, leaving a dip of five columns on the bottom row.
TAIL = {
    (34, 14): 8, (35, 14): 8,
    (34, 15): 12, (35, 15): 8, (36, 15): 8, (37, 15): 8,
    (46, 14): 8, (47, 14): 8,
    (43, 15): 8, (44, 15): 8, (45, 15): 8, (46, 15): 12,
}


def ink(v):
    return INKS[min(v, 64) // 4] if v >= FLOOR else "."


def sample():
    """The sheet's cloud rows as a red field on our grid, rows 11…15."""
    grid = json.load(open(os.path.join(HERE, "out", "native-moon.json")))["grid"]
    field = []
    for dy in range(ROWS):
        sy = SHEET_ROW0 + dy
        row = []
        for x in range(W):
            col = (x * 57 + 26) // 52
            c = grid[sy][col]
            v = 0 if c is None or (sy, col) in SHEET_STARS else c[0]
            if sy in BLOOM_ROWS and col in BLOOM_COLS:
                v = min(v, BLOOM_CAP)
            row.append(v if v >= FLOOR else 0)
        field.append(row)
    return field


def neighbours4(x, y, h):
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        yy = y + dy
        if 0 <= yy < h:
            yield (x + dx) % W, yy


def fill_holes(field):
    """Every off cell the sky cannot reach (4-connected through off cells from
    above the bank) becomes cloud at the mean of its cloud neighbours."""
    h = len(field)
    sky = {(x, -1) for x in range(W)}
    todo = list(sky)
    while todo:
        x, y = todo.pop()
        for nx, ny in neighbours4(x, y, h):
            if field[ny][nx] == 0 and (nx, ny) not in sky:
                sky.add((nx, ny))
                todo.append((nx, ny))
    changed = True
    while changed:
        changed = False
        for y in range(h):
            for x in range(W):
                if field[y][x] == 0 and (x, y) not in sky:
                    vals = [field[ny][nx] for nx, ny in neighbours4(x, y, h) if field[ny][nx]]
                    if vals:
                        field[y][x] = sum(vals) // len(vals)
                        changed = True
    return field


def smooth(field):
    """One 3×3 pass (centre 4, sides 2, corners 1) over cloud cells, using
    cloud neighbours only, so edges do not bleed."""
    h = len(field)
    out = [row[:] for row in field]
    for y in range(h):
        for x in range(W):
            if not field[y][x]:
                continue
            acc, wsum = 0, 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy = y + dy
                    if not 0 <= yy < h:
                        continue
                    v = field[yy][(x + dx) % W]
                    if v:
                        w = 4 if dx == 0 and dy == 0 else 2 if dx == 0 or dy == 0 else 1
                        acc, wsum = acc + w * v, wsum + w
            out[y][x] = (acc + wsum // 2) // wsum
    return out


def drop_specks(field):
    h = len(field)
    seen = set()
    for y in range(h):
        for x in range(W):
            if field[y][x] and (x, y) not in seen:
                blob, todo = {(x, y)}, [(x, y)]
                while todo:
                    cx, cy = todo.pop()
                    for nx, ny in neighbours4(cx, cy, h):
                        if field[ny][nx] and (nx, ny) not in blob:
                            blob.add((nx, ny))
                            todo.append((nx, ny))
                seen |= blob
                if len(blob) < MIN_BLOB:
                    for bx, by in blob:
                        field[by][bx] = 0
    return field


def prune_dangling(field):
    """A cloud cell with at most one cloud neighbour is a stray: off, until
    none is left."""
    h = len(field)
    changed = True
    while changed:
        changed = False
        for y in range(h):
            for x in range(W):
                if field[y][x] and sum(1 for nx, ny in neighbours4(x, y, h) if field[ny][nx]) <= 1:
                    field[y][x] = 0
                    changed = True
    return field


def main():
    field = prune_dangling(drop_specks(smooth(fill_holes(sample()))))
    for x, y in CORNERS:
        field[y - OUR_ROW0][x] = 0
    for x in range(47, W):                       # the far wisp becomes the shoulder
        for dy in range(ROWS):
            field[dy][x] = 0
    for table in (SHOULDER, TAIL):
        for (x, y), v in table.items():
            field[y - OUR_ROW0][x] = v
    front = ["".join(ink(v) for v in CREST_STEP) + "." * (W - len(CREST_STEP))]
    front += ["".join(ink(v) for v in row) for row in field]
    print(f"FRONT_Y = {OUR_ROW0 - 1}")
    print("FRONT = [")
    for r in front:
        print(f'    "{r}",')
    print("]")
    print("#", sum(r.count(c) for r in front for c in INKS[2:]), "px")


if __name__ == "__main__":
    main()
