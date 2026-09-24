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
FIXTURES = os.path.join(ROOT, "Tests", "PixelClockKitTests", "Fixtures")
OUT = os.path.join(FIXTURES, "usage_face_oracle.json")
CIRCLE_OUT = os.path.join(FIXTURES, "usage_circle_oracle.json")
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
    """The day first, which is the tile's default order.

    The tile also offers `sep 26 15:00`. That spelling is NOT recorded here,
    and deliberately: it is the same glyphs moved, so it is exactly as wide,
    and nothing about how a reset is centred or scrolled can differ. Recording
    it would double these fixtures to assert a string Python already proves in
    a unit test.
    """
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


# ── Circle ────────────────────────────────────────────────────────────────
# (id, vendor, [(window kind, percent, resetsAt)], dwellMs, resetAfter)
#
# The kinds are the tile's multi-select: one selected window is one turn and no
# transition, two are two turns with a count between them. The order is the
# order they are shown in, which is the order the windows are listed.
CIRCLE_CASES = [
    ("one-window-steady", "claude", [("fiveHour", 23, None)], 6_000, 80),
    ("one-window-hot", "claude", [("fiveHour", 84, utc(2026, 9, 23, 14, 30))], 6_000, 80),
    # The weekly reset is 55 columns against the 39 the rim frames, so this is
    # the case that scrolls — and the longest page Circle can build.
    ("one-window-marquee", "zai", [("weekly", 92, utc(2026, 9, 26, 15, 0))], 6_000, 80),
    ("both-steady", "claude",
     [("fiveHour", 23, None), ("weekly", 41, None)], 6_000, 80),
    ("both-session-hot", "claude",
     [("fiveHour", 84, utc(2026, 9, 23, 14, 30)), ("weekly", 52, None)], 6_000, 80),
    ("both-weekly-hot", "zai",
     [("fiveHour", 35, None), ("weekly", 92, utc(2026, 9, 26, 15, 0))], 8_000, 80),
    ("both-hot", "zai",
     [("fiveHour", 97, utc(2026, 9, 24, 9, 5)),
      ("weekly", 88, utc(2026, 10, 1, 9, 0))], 6_000, 80),
    # A full bucket pulses through its reading and then stands still for its
    # reset: text that blinks under the eye is text nobody finishes.
    ("spent", "claude",
     [("fiveHour", 104, utc(2026, 9, 23, 23, 59)),
      ("weekly", 88, utc(2026, 10, 1, 9, 0))], 6_000, 80),
    ("spent-no-reset", "claude", [("fiveHour", 100, None)], 10_000, 80),
    # Nothing to count to: a window with no reading cuts rather than sweeping,
    # because there is no value between 41% and "--".
    ("partial", "claude", [("fiveHour", 41, None), ("weekly", None, None)], 6_000, 80),
    ("no-data", "zai", [("fiveHour", None, None), ("weekly", None, None)], 6_000, 80),
    ("zero-and-one", "claude", [("fiveHour", 0, None), ("weekly", 1, None)], 6_000, 80),
    ("threshold-quiet", "zai",
     [("fiveHour", 72, utc(2026, 9, 23, 18, 10)),
      ("weekly", 61, utc(2026, 9, 28, 16, 0))], 6_000, 80),
    ("threshold-60-both", "claude",
     [("fiveHour", 72, utc(2026, 9, 23, 18, 10)),
      ("weekly", 61, utc(2026, 9, 28, 16, 0))], 20_000, 60),
    ("long-dwell", "claude", [("fiveHour", 55, None), ("weekly", 66, None)], 60_000, 80),
]

# What each window is CALLED on the panel — the period it measures, in the
# proportional face the rest of the layout is drawn in.
CIRCLE_NAMES = {"fiveHour": "5h", "weekly": "week"}


def circle_reset(kind, epoch):
    """The session names a time, the week names a date and a time. The rim
    frames 39 columns, which the first fits and the second never does."""
    if epoch is None:
        return ""
    return session_reset(epoch) if kind == "fiveHour" else weekly_reset(epoch)


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
    write(OUT, gen, cases)

    circles = []
    for cid, vendor, windows, dwell_ms, after in CIRCLE_CASES:
        timeline = gen.circle_timeline(
            vendor,
            [(CIRCLE_NAMES[kind], pct, circle_reset(kind, at)) for kind, pct, at in windows],
            dwell_ms=dwell_ms, threshold=after,
        )
        circles.append({
            "id": cid, "vendor": vendor,
            "windows": [{"kind": kind, "percent": pct, "resetsAt": at}
                        for kind, pct, at in windows],
            "dwellMs": dwell_ms, "resetAfter": after,
            "frames": [{"ms": ms, "rows": rows(cv)} for cv, ms in timeline],
        })
    write(CIRCLE_OUT, gen, circles)


def write(path, gen, cases):
    with open(path, "w") as f:
        json.dump({"timeZone": "UTC", "width": gen.W, "height": gen.H, "cases": cases},
                  f, indent=1)
        f.write("\n")
    print(f"{len(cases)} cases, {sum(len(c['frames']) for c in cases)} frames -> {path}")


if __name__ == "__main__":
    main()
