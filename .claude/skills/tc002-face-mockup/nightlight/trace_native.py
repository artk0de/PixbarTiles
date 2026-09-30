#!/usr/bin/env python3
"""Copies a sheet panel onto the 52×16 panel cell for cell — no resampling,
no redrawing — and writes it as a literal to `native_<scene>.py`.

The sheet's own grid (out/native-<scene>.json, from fit_grid.py) is 57×13
for the moon. Columns past 52 are sky and are cut; the three missing rows are
added as one blank row on top and two copies of the even haze row under the
moon, so no shape changes its cell count.

  python3 trace_native.py moon
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 52, 16
BLACK_BELOW = 30          # a cell dimmer than this (r+g+b) is black: true (0,0,0)

# Native row → panel rows, per scene.
ROW_MAP = {
    "moon": [[1], [2], [3], [4], [5], [6], [7], [8], [9], [10, 11, 12], [13], [14], [15]],
}


def main():
    name = sys.argv[1]
    grid = json.load(open(os.path.join(HERE, "out", f"native-{name}.json")))["grid"]
    out = [[None] * W for _ in range(H)]
    for j, targets in enumerate(ROW_MAP[name]):
        for y in targets:
            for x in range(W):
                c = tuple(grid[j][x])
                out[y][x] = None if sum(c) < BLACK_BELOW else c
    lines = [f'"""{name} traced cell for cell from mock-sheet.png by trace_native.py — do not edit by hand."""',
             "", "ROWS = ["]
    for row in out:
        lines.append("    [" + ", ".join("None" if c is None else f"({c[0]}, {c[1]}, {c[2]})" for c in row) + "],")
    lines.append("]")
    open(os.path.join(HERE, f"native_{name}.py"), "w").write("\n".join(lines) + "\n")
    lit = sum(1 for row in out for c in row if c)
    print(f"native_{name}.py: {lit} lit cells ({lit * 100 // (W * H)}% of the panel)")


if __name__ == "__main__":
    main()
