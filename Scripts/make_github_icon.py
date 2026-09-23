#!/usr/bin/env python3
"""Draw the AWTRIX GitHub icon from the TC002 face's own octicon.

The TC001 face shows the GitHub mark beside its text, and an AWTRIX icon is
8×8 art on the clock's flash. That art is not drawn by hand: it is ggen's
`glyph("mark", MARK, scale=0.5)` — the same 16×16 coverage table
(`github/octicons.py`), the same bilinear `sample` and the same lit / dim-edge
quantisation the TC002 face uses — cropped to the eight centred columns and
rows the half-scale draw lands on. At half scale every sample falls on the
corner of four source pixels, so bilinear IS the 2×2 box average.

Written through wgen's own GIF writer (full frames, one palette, GIF89a —
what `everyBundledIconIsAnEightByEightGIF` checks), as one frame: the mark's
shine is a TC002 loop, and the AWTRIX app shows its icon still.

Run from the repository root; deterministic, so a diff in the output means the
design (ggen, octicons, wgen) changed:

    python3 Scripts/make_github_icon.py [path/to/github-dir]
"""

from __future__ import annotations

import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, ".claude", "skills", "tc002-face-mockup", "github")
OUT = os.path.join(ROOT, "Sources", "PixelClockKit", "Resources", "GitHubMark.gif")
SIZE = 8
ORIGIN = (16 - SIZE) // 2   # a half-scale draw about the centre covers 4..11


def load(directory):
    sys.path.insert(0, directory)   # ggen imports octicons as a sibling, wgen from ../weather
    spec = importlib.util.spec_from_file_location("ggen", os.path.join(directory, "ggen.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["ggen"] = module
    spec.loader.exec_module(module)
    return module


def main():
    ggen = load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR)
    full = ggen.glyph("mark", ggen.MARK, scale=0.5)
    # Nothing outside the centred 8×8 may be lit, or the crop would cut the mark.
    for y in range(16):
        for x in range(16):
            inside = ORIGIN <= x < ORIGIN + SIZE and ORIGIN <= y < ORIGIN + SIZE
            assert inside or full[y][x] is None, f"lit pixel outside the icon at {x},{y}"
    icon = [row[ORIGIN:ORIGIN + SIZE] for row in full[ORIGIN:ORIGIN + SIZE]]
    blob = ggen.wgen.gif([(icon, 1000)], SIZE, SIZE)
    with open(OUT, "wb") as f:
        f.write(blob)
    for row in icon:
        print("".join("#" if px == ggen.MARK else ("+" if px else ".") for px in row))
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(blob)} bytes)")


if __name__ == "__main__":
    main()
