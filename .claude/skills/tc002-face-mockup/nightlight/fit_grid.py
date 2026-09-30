"""Finds a sheet panel's own cell grid (pitch and origin, per axis) and dumps
its cells one for one — no resampling, so a shape keeps its cell count.

  python3 fit_grid.py <scene>        # writes out/native-<scene>.json and prints the grid
"""
import json, os, pickle, sys

HERE = os.path.dirname(os.path.abspath(__file__))
px = pickle.load(open(os.path.join(HERE, "out", "sheet.pkl"), "rb"))
BOXES = {
    "embers": (44, 163, 738, 337), "horizon": (798, 163, 1492, 337),
    "moon": (44, 408, 738, 581), "fireflies": (798, 408, 1492, 581),
    "fireplace": (44, 647, 738, 820), "glow": (798, 647, 1492, 820),
}
lum = lambda c: c[0] + c[1] + c[2]


def profile(l, t, r, b, axis):
    """Mean lum per column (axis 0) or row (axis 1), dark pixels only: on black
    the grid lines are the brightest thing there."""
    n = (r - l) if axis == 0 else (b - t)
    acc, cnt = [0] * n, [0] * n
    for y in range(t + 2, b - 2):
        for x in range(l + 2, r - 2):
            v = lum(px[y][x])
            if v < 90:
                i = (x - l) if axis == 0 else (y - t)
                acc[i] += v
                cnt[i] += 1
    return [a / c if c else 0 for a, c in zip(acc, cnt)]


def fit(prof):
    """The pitch and origin whose predicted lines sit on the brightest columns."""
    best = (0, 0, 0)
    for p100 in range(1000, 1500):
        p = p100 / 100
        for o10 in range(0, int(p * 10)):
            o = o10 / 10
            xs, k = [], 0
            while o + k * p < len(prof) - 1:
                xs.append(int(round(o + k * p)))
                k += 1
            if len(xs) < 8:
                continue
            score = sum(prof[x] for x in xs) / len(xs)
            if score > best[0]:
                best = (score, p, o)
    return best


def main():
    name = sys.argv[1]
    l, t, r, b = BOXES[name]
    l, t, r, b = l + 1, t + 1, r - 1, b - 1
    _, px_, ox = fit(profile(l, t, r, b, 0))
    _, py_, oy = fit(profile(l, t, r, b, 1))
    cols = int((r - l - ox) / px_)
    rows = int((b - t - oy) / py_)
    print(f"{name}: pitch {px_:.2f}×{py_:.2f}, origin +{ox:.1f},+{oy:.1f} → {cols}×{rows} cells")
    grid = []
    for j in range(rows):
        line = []
        for i in range(cols):
            cx = l + ox + (i + 0.5) * px_
            cy = t + oy + (j + 0.5) * py_
            acc, n = [0, 0, 0], 0
            for yy in range(int(cy) - 2, int(cy) + 3):
                for xx in range(int(cx) - 2, int(cx) + 3):
                    c = px[yy][xx]
                    acc = [acc[k] + c[k] for k in range(3)]
                    n += 1
            line.append([a // n for a in acc])
        grid.append(line)
    json.dump({"pitch": [px_, py_], "origin": [ox, oy], "grid": grid},
              open(os.path.join(HERE, "out", f"native-{name}.json"), "w"))
    for j, line in enumerate(grid):
        print(f"{j:2}", "".join(" " if lum(c) < 40 else "." if lum(c) < 70 else "-" if lum(c) < 110
                                else "o" if lum(c) < 200 else "O" if lum(c) < 300 else "@" for c in line))


if __name__ == "__main__":
    main()
