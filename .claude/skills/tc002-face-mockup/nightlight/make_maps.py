#!/usr/bin/env python3
"""Turns the mock sheet's panels (out/sheet-52x16.json, from probe_sheet.py)
into the intensity maps the scenes start from, written to maps.py.

A cell's colour becomes the ramp intensity whose colour is nearest to it, so a
map drawn back through `ngen.ramp` is the sheet in the tile's own palette.
Re-run only when the reference sheet changes; maps.py is committed and is what
the Swift side copies.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]
import ngen  # noqa: E402

SCENES = ["embers", "horizon", "moon"]
CUT_LUM = 60          # a sheet cell dimmer than this is an unlit dot


def nearest(c):
    if sum(c) < CUT_LUM:
        return 0
    best, bestd = 0, 10 ** 9
    for v in range(ngen.CUT, 256):
        r = ngen.ramp(v)
        d = sum((r[k] - c[k]) ** 2 for k in range(3))
        if d < bestd:
            best, bestd = v, d
    return best


def main():
    sheet = json.load(open(os.path.join(HERE, "out", "sheet-52x16.json")))
    lines = ['"""Intensity maps traced from mock-sheet.png by make_maps.py — do not edit by hand.',
             '', 'One string of 52 two-digit hex intensities per row, 16 rows per scene."""', '', 'MAPS = {']
    for name in SCENES:
        lines.append(f'    "{name}": [')
        for row in sheet[name]:
            lines.append('        "' + "".join(f"{nearest(tuple(c)):02x}" for c in row) + '",')
        lines.append('    ],')
    lines.append('}')
    open(os.path.join(HERE, "maps.py"), "w").write("\n".join(lines) + "\n")
    print("maps.py written:", ", ".join(SCENES))


if __name__ == "__main__":
    main()
