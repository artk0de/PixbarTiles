"""Throwaway: resample each of the sheet's six panels to the clock's 52×16 grid
and write them as reference maps (out/sheet-52x16.json) plus a PNG each."""
import json, os, pickle, sys
import pngread

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [os.path.dirname(HERE)]
OUT = os.path.join(HERE, "out")
cache = os.path.join(OUT, "sheet.pkl")
os.makedirs(OUT, exist_ok=True)
if os.path.exists(cache):
    px = pickle.load(open(cache, "rb"))
else:
    _, _, px = pngread.read(os.path.join(HERE, "mock-sheet.png"))
    pickle.dump(px, open(cache, "wb"))
lum = lambda c: c[0] + c[1] + c[2]
W, H = 52, 16
NAMES = [["embers", "horizon"], ["moon", "fireflies"], ["fireplace", "glow"]]
LEFTS = [44, 798]


def frame_rows(x):
    """The y of every bright horizontal frame line crossing column x."""
    ys = [y for y in range(100, 900) if lum(px[y][x]) > 100 and lum(px[y][x + 40]) > 100 and lum(px[y][x + 90]) > 100]
    runs = []
    for y in ys:
        if runs and y - runs[-1][-1] <= 1:
            runs[-1].append(y)
        else:
            runs.append([y])
    return [r[0] for r in runs]


maps = {}
for col, left in enumerate(LEFTS):
    for row, (top, bottom) in enumerate(((163, 337), (408, 581), (647, 820))):
        l, r, t, b = left + 1, left + 694 - 1, top + 1, bottom - 1
        grid = []
        for j in range(H):
            line = []
            for i in range(W):
                x0, x1 = l + (r - l) * i // W, l + (r - l) * (i + 1) // W
                y0, y1 = t + (b - t) * j // H, t + (b - t) * (j + 1) // H
                best, bestv = (0, 0, 0), -1
                for yy in range(y0 + 2, y1 - 1):
                    for xx in range(x0 + 2, x1 - 1):
                        acc = [0, 0, 0]
                        for dy in (-1, 0, 1):
                            for dx in (-1, 0, 1):
                                c = px[yy + dy][xx + dx]
                                acc = [acc[k] + c[k] for k in range(3)]
                        c = tuple(a // 9 for a in acc)
                        if lum(c) > bestv:
                            best, bestv = c, lum(c)
                line.append(best)
            grid.append(line)
        name = NAMES[row][col]
        maps[name] = grid
        print(name, "panel", (l, t, r, b))

import gen, ngen  # noqa: E402
gen.W, gen.H = W, H
for name, grid in maps.items():
    cv = gen.Canvas()
    for y in range(H):
        for x in range(W):
            c = grid[y][x]
            cv.px[y][x] = c if lum(c) > 60 else None
    ngen.png(cv, os.path.join(OUT, f"sheet-{name}.png"))
json.dump(maps, open(os.path.join(OUT, "sheet-52x16.json"), "w"))
