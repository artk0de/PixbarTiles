#!/usr/bin/env python3
"""Record the approved TC002 animated scenes as the Swift engine's oracle.

The night-light scenes were approved in the browser and on the clock as the
frames `tc002-face-mockup/nightlight/ngen.py` computes through the shared
`nlengine.py`. This writes `Tests/PixbarKitTests/Fixtures/animation_oracle.json`:

- per scene the default variant (1×, brightness 5, every layer moving) as
  full frames: a palette of "rrggbb" (index 0 black) and one string per frame
  of two hex digits per pixel, row-major, stored as `framesZ` — base64 of the
  raw DEFLATE of the JSON list (Foundation's `.zlib` inflates exactly this);
- every other variant (speeds × stilled layers at brightness 5, brightness
  1–4 at 1×) as its frame count and one FNV-1a-64 over every frame's RGB
  bytes, row-major, black as 0,0,0.

Run from the repository root:  python3 Scripts/make_animation_oracle.py

Rerun it after a design change in the skill, never to make a failing Swift
test pass: the fixture is the approved design.
"""
import base64, itertools, json, os, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = os.path.join(ROOT, ".claude", "skills", "tc002-face-mockup")
NIGHT = os.path.join(SKILL, "nightlight")
sys.path[:0] = [NIGHT, SKILL]
import ngen  # noqa: E402

OUT = os.path.join(ROOT, "Tests", "PixbarKitTests", "Fixtures", "animation_oracle.json")
SPEEDS = {"1/2": (1, 2), "1/1": (1, 1), "2/1": (2, 1)}


def frames(sid, level, speed, off):
    return [[[cv.px[y][x] or (0, 0, 0) for x in range(ngen.W)] for y in range(ngen.H)]
            for cv, _ in ngen.timeline(sid, level, speed, off)]


def fnv(frame_list):
    h = 0xCBF29CE484222325
    for f in frame_list:
        for row in f:
            for px in row:
                for b in px:
                    h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def deflate(obj):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw = c.compress(json.dumps(obj, separators=(",", ":")).encode()) + c.flush()
    return base64.b64encode(raw).decode()


def main():
    scenes, variants = {}, []
    for sid, _, _ in ngen.SCENES:
        ps = ngen.ENGINE[sid]
        toggles = ngen.toggles(sid)
        default = frames(sid, 5, (1, 1), frozenset())
        palette = [(0, 0, 0)]
        index = {(0, 0, 0): 0}
        rows = []
        for f in default:
            s = []
            for row in f:
                for px in row:
                    if px not in index:
                        index[px] = len(palette)
                        palette.append(px)
                    s.append("%02x" % index[px])
            rows.append("".join(s))
        scenes[sid] = {"frameMs": ps.frame_ms, "cycleFrames": ps.cycle_frames, "toggles": toggles,
                       "palette": ["%02x%02x%02x" % c for c in palette], "framesZ": deflate(rows)}
        for name, speed in SPEEDS.items():
            for k in range(len(toggles) + 1):
                for off in itertools.combinations(toggles, k):
                    fl = frames(sid, 5, speed, frozenset(off))
                    variants.append({"scene": sid, "speed": name, "stilled": list(off), "brightness": 5,
                                     "frames": len(fl), "fnv": fnv(fl)})
        for level in (1, 2, 3, 4):
            fl = frames(sid, level, (1, 1), frozenset())
            variants.append({"scene": sid, "speed": "1/1", "stilled": [], "brightness": level,
                             "frames": len(fl), "fnv": fnv(fl)})
        print(f"{sid:10} {len(default):3} frames, {len(palette):2} colours")
    with open(OUT, "w") as fh:
        json.dump({"W": ngen.W, "H": ngen.H, "scenes": scenes, "variants": variants}, fh,
                  separators=(",", ":"), sort_keys=True)
    print(OUT, os.path.getsize(OUT), "bytes,", len(variants), "variants")


if __name__ == "__main__":
    main()
