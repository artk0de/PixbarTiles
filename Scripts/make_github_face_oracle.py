#!/usr/bin/env python3
"""Record the approved TC002 GitHub face as the Swift face's oracle.

The face was approved in the browser and on the clock as the frames the
`tc002-face-mockup` skill's `github/ggen.py` computes (with the octicon
coverage in `github/octicons.py` and the building blocks it takes from
`weather/wgen.py`) — those files are the only source of the design. The Swift
`GitHubFace` is held to them by comparing against their own output, never
against values typed from a screenshot.

This writes `Tests/PixbarKitTests/Fixtures/github_face_oracle.json`:

- `glyphs`: the rows ggen ADDS to wgen's tables — `small` (`G`: `j _ + # ☺`)
  and `big` (`B`: `+ k m ★ c i ⑂ ⎇`) — as strings of `#` / `.`.
- `octicons`: `octicons.OCTICONS` as it is, sixteen rows of 32 hex digits per
  icon (one coverage byte per pixel).
- `cases`: every `ggen.CASES` entry at `dwell=10000, celebrate=8000`, plus
  `a1-steady` at `dwell=5000`. A case carries its input as the Swift side
  receives it (`kind`; the reading's `repo`/`stars`/`forks`/`prs`/`ci` or
  null, `shortName`, `token`, `problem` and the Show toggles `showForks` /
  `showPRs` / `showCI` and the Main watch `main` for an ambient case;
  `count`, `who`, `prNumbers`
  for a celebration, and `branch` for a `ci` one) and ggen's timeline as `framesZ`: base64 of the raw DEFLATE
  (no zlib header) of the compact JSON `[{"ms", "rows"}]`, every frame as
  sixteen rows of packed `RRGGBB` hex — the weather oracle's format, which
  Foundation's `NSData.decompressed(using: .zlib)` inflates.

Run from the repository root:

    python3 Scripts/make_github_face_oracle.py [path/to/github-dir]

Rerun it after the design changes in the skill, never to make a failing Swift
test pass: the fixture is the approved design, and a new one is a new design.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, ".claude", "skills", "tc002-face-mockup", "github")
OUT = os.path.join(ROOT, "Tests", "PixbarKitTests", "Fixtures", "github_face_oracle.json")
SMALL_ADDED = ["j", "_", "+", "#", "☺"]
BIG_ADDED = ["+", "k", "m", "★", "c", "i", "⑂", "⎇"]


def load(directory):
    sys.path.insert(0, directory)   # ggen imports octicons as a sibling, wgen from ../weather
    spec = importlib.util.spec_from_file_location("ggen", os.path.join(directory, "ggen.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["ggen"] = module
    spec.loader.exec_module(module)
    return module


def hexrows(grid):
    return ["".join("%02x%02x%02x" % (px or (0, 0, 0)) for px in row) for row in grid]


def deflate(obj):
    """base64 of raw DEFLATE (wbits -15) of compact, key-sorted JSON."""
    raw = json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    return base64.b64encode(z.compress(raw) + z.flush()).decode()


def case_json(ggen, c, cid, dwell, celebrate):
    frames = ggen.build(c, dwell=dwell, celebrate=celebrate)
    out = {"id": cid, "kind": c["kind"], "dwell": dwell, "celebrate": celebrate}
    if c["kind"] == "ambient":
        r = c["reading"]
        out["reading"] = None if r is None else {"repo": r.repo, "stars": r.stars, "forks": r.forks, "prs": r.prs,
                                                "ci": r.ci}
        out["shortName"] = c.get("short_name")
        out["token"] = c.get("token", True)
        # Why there is no reading (`token` / `repo` / `data`), or null; and
        # the tile's Show toggles, each on unless the case turns it off.
        out["problem"] = c.get("problem")
        out["showForks"] = c.get("show_forks", True)
        out["showPRs"] = c.get("show_prs", True)
        out["showCI"] = c.get("show_ci", True)
        # The Main watch: which of stars / prs / forks / ci holds the hero.
        out["main"] = c.get("main", "stars")
    else:
        out["count"] = c["count"]
        out["who"] = c["who"]
        if c["kind"] == "ci":
            # ggen carries the failing branch in `prs`; the Swift side takes
            # it as its own field and has no PR numbers to show.
            out["branch"] = c["prs"][0]
            out["prNumbers"] = []
        else:
            out["prNumbers"] = list(c.get("prs", ()))
    out["frameCount"] = len(frames)
    out["framesZ"] = deflate([{"ms": ms, "rows": hexrows(g)} for g, ms in frames])
    return out, frames


def main():
    ggen = load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR)
    ids = [c["id"] for c in ggen.CASES]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate case ids")

    cases, largest = [], None
    runs = [(c, c["id"], 10_000, 8_000) for c in ggen.CASES]
    a1 = next(c for c in ggen.CASES if c["id"] == "a1-steady")
    runs.append((a1, "a1-steady-dwell-5000", 5_000, 8_000))
    for c, cid, dwell, celebrate in runs:
        entry, frames = case_json(ggen, c, cid, dwell, celebrate)
        cases.append(entry)
        if largest is None or len(frames) > largest[1]:
            largest = (cid, len(frames))

    glyphs = {
        "small": {ch: ggen.G[ch] for ch in SMALL_ADDED},
        "big": {ch: ggen.B[ch] for ch in BIG_ADDED},
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"width": ggen.W, "height": ggen.H, "areaX": ggen.AREA_X, "glyphs": glyphs,
                   "octicons": ggen.OCTICONS, "cases": cases}, f, indent=1, ensure_ascii=False)
        f.write("\n")
    total = sum(e["frameCount"] for e in cases)
    print(f"{len(cases)} cases, {total} frames -> {OUT}")
    print(f"largest: {largest[0]} ({largest[1]} frames)")


if __name__ == "__main__":
    main()
