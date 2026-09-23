#!/usr/bin/env python3
"""Record the approved TC002 usage face's frames as the Swift face's oracle.

The face was approved in the browser and on the clock as the frames the
`tc002-face-mockup` skill's `gen.py` computes — that file is the only source of
the design's pixels. The Swift `UsageFace` must reproduce them exactly, and it
can only be held to that by comparing against gen.py's own output rather than
against values somebody typed from a screenshot.

This writes the fixture `UsageFaceOracleTests` compares against: for each case,
the inputs as the Swift side receives them (percentages, reset INSTANTS as
epoch seconds, the two tile parameters) and gen.py's timeline — every frame as
sixteen rows of packed `RRGGBB` hex, with its duration in milliseconds.

Reset instants are formatted here in UTC, the zone the Swift test injects:
`rst HH:mm` for the session, `rst d mmm HH:mm` for the week — the spellings
the design names, fed to gen.py as the strings it draws.

Run from the repository root:

    python3 Scripts/make_usage_face_oracle.py [path/to/gen.py]

Rerun it after the design changes in gen.py, never to make a failing Swift
test pass: the fixture is the approved design, and a new one is a new design.
"""

from __future__ import annotations

import calendar
import importlib.util
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_GEN = os.path.join(ROOT, ".claude", "skills", "tc002-face-mockup", "gen.py")
OUT = os.path.join(ROOT, "Tests", "PixelClockKitTests", "Fixtures", "usage_face_oracle.json")
MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()


def load_gen(path):
    # gen.py writes its HTML output under OUT at import; point that at a
    # scratch directory so recording the oracle leaves no mockup behind.
    os.environ.setdefault("OUT", os.path.join("/tmp", "usage-face-oracle-mockup"))
    spec = importlib.util.spec_from_file_location("gen", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def utc(y, mo, d, h, mi):
    return calendar.timegm((y, mo, d, h, mi, 0))


def session_reset(epoch):
    return time.strftime("%H:%M", time.gmtime(epoch))


def weekly_reset(epoch):
    t = time.gmtime(epoch)
    return f"{t.tm_mday} {MONTHS[t.tm_mon - 1]} {t.tm_hour:02d}:{t.tm_min:02d}"


def window(percent, resets_at=None):
    return {"percent": percent, "resetsAt": resets_at}


# (id, vendor, session, weekly, resetEveryMs, resetAfter)
CASES = [
    ("steady", "claude", window(23), window(41), 10_000, 80),
    ("session-hot-only", "claude", window(84, utc(2026, 9, 23, 14, 30)), window(52), 10_000, 80),
    ("weekly-hot-marquee", "zai", window(35), window(92, utc(2026, 9, 26, 15, 0)), 5_000, 80),
    ("both-hot", "claude", window(97, utc(2026, 9, 24, 9, 5)),
     window(88, utc(2026, 10, 1, 9, 0)), 15_000, 80),
    ("both-hot-zai", "zai", window(97, utc(2026, 9, 24, 9, 5)),
     window(88, utc(2026, 10, 1, 9, 0)), 30_000, 80),
    ("spent-cap", "zai", window(104, utc(2026, 9, 23, 23, 59)),
     window(100, utc(2026, 9, 30, 23, 59)), 60_000, 80),
    # A full bucket whose source named no reset: the pulse with no reset phase
    # after it, which is the only shape where frame A is the whole page.
    ("spent-no-reset", "claude", window(100), window(30), 10_000, 80),
    ("zero-and-three", "claude", window(0), window(3), 10_000, 80),
    ("no-data", "zai", window(None), window(None), 10_000, 80),
    ("no-data-claude", "claude", window(None), window(None), 10_000, 80),
    ("partial", "claude", window(12), window(None), 120_000, 80),
    ("threshold-80-quiet", "zai", window(72, utc(2026, 9, 23, 18, 10)),
     window(61, utc(2026, 9, 28, 16, 0)), 10_000, 80),
    ("threshold-70-session", "zai", window(72, utc(2026, 9, 23, 18, 10)),
     window(61, utc(2026, 9, 28, 16, 0)), 10_000, 70),
    ("threshold-60-both", "claude", window(72, utc(2026, 9, 23, 18, 10)),
     window(61, utc(2026, 9, 28, 16, 0)), 300_000, 60),
    ("threshold-100-exact", "claude", window(100, utc(2026, 9, 23, 18, 10)),
     window(99, utc(2026, 9, 28, 16, 0)), 10_000, 100),
]


def rows(canvas):
    return ["".join("%02x%02x%02x" % (px or (0, 0, 0)) for px in row) for row in canvas.px]


def main():
    gen = load_gen(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_GEN)
    cases = []
    for cid, vendor, session, weekly, every_ms, after in CASES:
        s = gen.R(session["percent"],
                  session_reset(session["resetsAt"]) if session["resetsAt"] else "")
        w = gen.R(weekly["percent"],
                  weekly_reset(weekly["resetsAt"]) if weekly["resetsAt"] else "")
        timeline = gen.timeline(vendor, s, w, interval_ms=every_ms, threshold=after)
        cases.append({
            "id": cid, "vendor": vendor, "session": session, "weekly": weekly,
            "resetEveryMs": every_ms, "resetAfter": after,
            "frames": [{"ms": ms, "rows": rows(cv)} for cv, ms in timeline],
        })
    with open(OUT, "w") as f:
        json.dump({"timeZone": "UTC", "width": gen.W, "height": gen.H, "cases": cases},
                  f, indent=1)
        f.write("\n")
    print(f"{len(cases)} cases, {sum(len(c['frames']) for c in cases)} frames -> {OUT}")


if __name__ == "__main__":
    main()
