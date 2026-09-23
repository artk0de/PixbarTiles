#!/usr/bin/env python3
"""Record the approved TC002 weather face as the Swift face's oracle.

The face was approved in the browser and on the clock as the pixels the
`tc002-face-mockup` skill's `weather/wgen.py` and `weather/icons.py` compute —
those files are the only source of the design. The Swift face is held to them
by comparing against their own output, never against values typed from a
screenshot.

This writes two fixtures under `Tests/PixelClockKitTests/Fixtures/`:

- `weather_icons_oracle.json` — every icon's animation, palette-indexed:
  `{"icons": {name: {"palette": ["rrggbb"], "frames": [{"ms", "rows"}]}}}`,
  each row sixteen base-36 palette indices; index 0 is `000000`, unlit.
- `weather_face_oracle.json` — the glyph tables and the cases. A case is the
  input as the Swift side receives it (a reading in °C, km/h and epoch
  seconds, `null` where a field is missing; the tile's config), the facts
  wgen derives, and wgen's timeline: Anchor's `icon` and `area`, or Pages'
  and Hybrid's `full`, every frame as rows of packed `RRGGBB` hex with its
  duration in milliseconds. `burst` is the fallback the budget rule picked.
  The frames are stored as `framesZ`: base64 of the raw DEFLATE (no zlib
  header) of the compact JSON of that `{"icon", "area"}` / `{"full"}` object —
  hex rows repeat so much that this keeps the fixture small. Foundation's
  `NSData.decompressed(using: .zlib)` inflates exactly this format.

Times are formatted in UTC, the zone the Swift tests inject.

Run from the repository root:

    python3 Scripts/make_weather_face_oracle.py [path/to/weather-dir]

Rerun it after the design changes in the skill, never to make a failing Swift
test pass: the fixture is the approved design, and a new one is a new design.
"""

from __future__ import annotations

import base64
import calendar
import importlib.util
import json
import math
import os
import sys
import zlib
from datetime import timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, ".claude", "skills", "tc002-face-mockup", "weather")
FIXTURES = os.path.join(ROOT, "Tests", "PixelClockKitTests", "Fixtures")
ICONS_OUT = os.path.join(FIXTURES, "weather_icons_oracle.json")
FACE_OUT = os.path.join(FIXTURES, "weather_face_oracle.json")
DIGITS36 = "0123456789abcdefghijklmnopqrstuvwxyz"


def load(directory):
    sys.path.insert(0, directory)   # wgen imports icons as a sibling
    spec = importlib.util.spec_from_file_location("wgen", os.path.join(directory, "wgen.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["wgen"] = module    # dataclasses resolve annotations through it
    spec.loader.exec_module(module)
    return module


def utc(y, mo, d, h=0, mi=0, s=0):
    return calendar.timegm((y, mo, d, h, mi, s))


DAY = utc(2026, 9, 23)          # the reading's local day (UTC here)
NOON = DAY + 14 * 3600 + 20 * 60          # 14:20, mid-hour on purpose
NIGHT = DAY + 23 * 3600 + 40 * 60         # 23:40, after sunset
DAWN = DAY + 5 * 3600 + 10 * 60           # 05:10, before sunrise
SUNRISES = [DAY + 6 * 3600 + 48 * 60 + 41, DAY + 86400 + 6 * 3600 + 50 * 60 + 2]
SUNSETS = [DAY + 19 * 3600 + 2 * 60 + 9, DAY + 86400 + 18 * 3600 + 59 * 60 + 47]


def hourly(t0=16.0, swing=5.0, pops=None):
    """48 hourly points from the day's midnight: a daily sine around t0, and
    precipitation probabilities (a function of the hour index) or None."""
    out = []
    for i in range(48):
        t = round(t0 + swing * math.sin((i - 9) / 24 * 2 * math.pi), 1)
        out.append((DAY + i * 3600, t, pops(i) if pops else 10))
    return out


BASE = dict(code=0, is_day=True, t=18.4, fl=17.2, hum=64, wind_kmh=12.6, wdir=225, gust_kmh=21.6,
            uv=4.4, hi=21.3, lo=12.8, sunrise=SUNRISES, sunset=SUNSETS, hourly=hourly())


def kmh(ms):
    return round(ms * 3.6, 1)


ALL = ("feels", "humidity", "wind", "hilo", "rain", "uv", "sun", "hourly")
DEFAULT = ("feels", "humidity", "wind", "hilo", "rain", "hourly")
RULE_ITEMS = ("feels", "wind")


def case(cid, now=NOON, reading="base", layout="anchor", every=3, units="c", wind="m/s",
         feels_colour=True, items=RULE_ITEMS, **fields):
    """A case: the base reading with `fields` overridden (None = missing)."""
    if reading is None:
        r = None
    else:
        r = {**BASE, **fields}
    return dict(id=cid, now=now, reading=r, layout=layout, every=every, units=units, wind=wind,
                feels_colour=feels_colour, items=items)


def pops(value, hours_=range(48)):
    return lambda i: value if i in hours_ else 5


CASES = [
    # ---- one case per icon rule (spec §4.1), Anchor ----
    case("rule-nodata", reading=None),
    case("rule-hail-96", code=96, hourly=hourly(pops=pops(90))),
    case("rule-hail-99-night", now=NIGHT, code=99, is_day=False),
    case("rule-thunder-95", code=95, wind_kmh=kmh(8), gust_kmh=kmh(15)),
    case("rule-storm-95-wind", code=95, wind_kmh=kmh(14), gust_kmh=kmh(16)),
    case("rule-storm-95-gusts", code=95, wind_kmh=kmh(8), gust_kmh=kmh(20)),
    case("rule-blizzard-73-windy", code=73, t=-6.2, fl=-13.9, wind_kmh=kmh(11), gust_kmh=kmh(16)),
    case("rule-blizzard-85-gusts", code=85, t=-3.0, fl=-9.0, wind_kmh=kmh(6), gust_kmh=kmh(15)),
    case("rule-snow-showers-85-day", code=85, t=-2.4, fl=-6.1, wind_kmh=kmh(4), gust_kmh=kmh(7)),
    case("rule-snow-showers-86-night", now=NIGHT, code=86, is_day=False, t=-4.0, fl=-8.0,
         wind_kmh=kmh(3), gust_kmh=kmh(5)),
    case("rule-snow-71", code=71, t=-1.2, fl=-4.4),
    case("rule-snow-77-night", now=NIGHT, code=77, is_day=False, t=-8.0, fl=-12.0),
    case("rule-freezing-rain-56", code=56, t=-0.8, fl=-4.0),
    case("rule-freezing-rain-67", code=67, t=-2.0, fl=-5.5),
    case("rule-sleet-61-at-1c", code=61, t=1.0, fl=-2.3),
    case("rule-sleet-80-at-0c", code=80, t=0.0, fl=-3.0),
    case("rule-drizzle-53", code=53, t=9.4, fl=7.8),
    case("rule-drizzle-51-at-2-1c", code=51, t=2.1, fl=0.4),
    case("rule-rain-63", code=63, t=13.6, fl=12.9),
    case("rule-heavy-rain-65", code=65, t=15.0, fl=14.1),
    case("rule-heavy-rain-82", code=82, t=17.0, fl=16.2),
    case("rule-showers-80-day", code=80, t=17.3, fl=16.0),
    case("rule-showers-81-night", now=NIGHT, code=81, is_day=False, t=12.0, fl=11.0),
    case("rule-fog-45", code=45, t=3.2, fl=1.1, hum=100),
    case("rule-rime-fog-48", code=48, t=-3.1, fl=-6.0, hum=98),
    case("rule-windy-day-0", code=0, wind_kmh=kmh(10), gust_kmh=kmh(13)),
    case("rule-windy-night-2-gusts", now=NIGHT, code=2, is_day=False, wind_kmh=kmh(6), gust_kmh=kmh(15)),
    case("rule-cloud-windy-3", code=3, wind_kmh=kmh(12), gust_kmh=kmh(18)),
    case("rule-hot-0-day", code=0, t=31.2, fl=33.0, hi=33.8, lo=22.1),
    case("rule-hot-1-at-30c", code=1, t=30.0, fl=31.0, hi=32.0, lo=21.0),
    case("rule-frosty-clear-1-day", code=1, t=-12.3, fl=-18.0, hi=-9.0, lo=-16.0),
    case("rule-cold-clear-night-not-frosty", now=NIGHT, code=1, is_day=False, t=-14.0, fl=-19.0),
    case("rule-clear-day-0", code=0),
    case("rule-moon-0-night", now=NIGHT, code=0, is_day=False, t=9.0, fl=7.0),   # moon off: clearNight
    case("rule-moon-new", now=utc(2026, 9, 11, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None),   # another day: no daily or hourly data
    case("rule-moon-full", now=utc(2026, 9, 26, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None),   # another day: no daily or hourly data
    # showsMoon on: a clear night is the moon in its phase
    case("rule-moon-shown-0-night", now=NIGHT, code=0, is_day=False, t=9.0, fl=7.0, items=RULE_ITEMS + ("moon",)),
    case("rule-moon-shown-new", now=utc(2026, 9, 11, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None, items=RULE_ITEMS + ("moon",)),
    case("rule-moon-shown-full", now=utc(2026, 9, 26, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None, items=RULE_ITEMS + ("moon",)),
    case("rule-moon-shown-cloudy-night-unchanged", now=NIGHT, code=2, is_day=False, t=8.0, fl=6.0,
         items=RULE_ITEMS + ("moon",)),
    case("rule-mainly-clear-day-1", code=1),
    case("rule-mainly-clear-night-1", now=NIGHT, code=1, is_day=False, t=10.0, fl=9.0),
    case("rule-partly-cloudy-day-2", code=2),
    case("rule-partly-cloudy-night-2", now=NIGHT, code=2, is_day=False, t=8.0, fl=6.0),
    case("rule-cloud-day-3", code=3),
    case("rule-cloud-night-3", now=NIGHT, code=3, is_day=False, t=7.0, fl=5.0),
    case("rule-unknown-code-falls-back-to-clear", code=7),

    # ---- each layout on three readings ----
    case("anchor-thunder-default", code=95, t=22.4, fl=25.1, wind_kmh=kmh(6), gust_kmh=kmh(15),
         items=DEFAULT, every=10),
    case("anchor-all-details", code=2, items=ALL, every=5),
    case("anchor-feels-colour-off", code=63, t=4.0, fl=-1.0, items=("feels", "hilo"), feels_colour=False),
    case("hybrid-thunder", code=95, t=22.4, fl=25.1, wind_kmh=kmh(6), gust_kmh=kmh(15), layout="hybrid",
         items=DEFAULT),
    case("hybrid-snow-feels", code=73, t=-12.0, fl=-19.0, hi=-9.0, lo=-15.0, layout="hybrid",
         items=("feels", "humidity", "hilo", "sun")),
    case("hybrid-clear-night-sun-uv", now=NIGHT, code=0, is_day=False, layout="hybrid",
         items=("uv", "sun", "rain")),
    case("hybrid-storm-default-10s", code=95, t=19.0, fl=16.0, hum=90, wind_kmh=kmh(17), wdir=270,
         gust_kmh=kmh(25), hi=21.0, lo=15.0, hourly=hourly(19, 3, pops(95)), layout="hybrid",
         items=DEFAULT, every=10),
    case("pages-rain", code=63, t=14.0, fl=13.0, hum=95, hourly=hourly(pops=pops(90)), layout="pages",
         items=DEFAULT),
    case("pages-cold-minus-35", code=0, t=-35.0, fl=-44.0, hi=-30.0, lo=-38.0, layout="pages", items=ALL),
    case("pages-gusts-kmh", code=3, wind_kmh=kmh(9), gust_kmh=kmh(17), wdir=315, layout="pages",
         wind="km/h", items=("wind", "humidity")),

    # ---- units and extremes ----
    case("fahrenheit-mph", code=1, units="f", wind="mph", items=ALL, every=5),
    case("fahrenheit-104", code=0, t=40.0, fl=43.9, hi=41.1, lo=27.8, wind_kmh=kmh(4), gust_kmh=kmh(7),
         units="f", wind="mph", items=("feels", "hilo", "wind")),
    case("fahrenheit-104-pages", code=0, t=40.0, fl=43.9, hi=41.1, lo=27.8, units="f", wind="mph",
         layout="pages", items=("feels", "wind")),
    case("minus-35-anchor", code=0, t=-35.0, fl=-44.0, hi=-30.0, lo=-38.0, items=("feels", "hilo")),
    case("gusts-anchor", code=3, wind_kmh=kmh(8), gust_kmh=kmh(17), wdir=30, items=("wind",)),
    case("gusts-below-five-hidden", code=3, wind_kmh=kmh(8), gust_kmh=kmh(12.9), wdir=100,
         items=("wind", "humidity")),
    case("wind-kmh", code=2, wind_kmh=33.3, gust_kmh=40.0, wdir=359, wind="km/h", items=("wind", "uv")),
    case("uv-extreme", code=0, uv=11.4, items=("uv", "rain")),

    # ---- sun events and the rain window ----
    case("sun-before-sunrise", now=DAWN, code=0, is_day=False, items=("sun", "rain")),
    case("sun-after-sunset", now=NIGHT, code=0, is_day=False, items=("sun", "hourly")),
    case("sun-daytime-set", code=0, items=("sun", "hourly")),
    case("rain-window-next-two-hours", code=3, hourly=hourly(pops=lambda i: {14: 20, 15: 35, 16: 70, 17: 99}.get(i, 0)),
         items=("rain", "hourly")),
    case("rain-below-30-grey", code=3, hourly=hourly(pops=pops(25)), items=("rain",)),
    case("hourly-flat", code=3, hourly=hourly(swing=0), items=("hourly",)),

    # ---- each optional field missing (all details on, the missing one drops) ----
    case("missing-feels", fl=None, items=ALL),
    case("missing-humidity", hum=None, items=ALL),
    case("missing-wind-direction", wdir=None, items=ALL),
    case("missing-gusts", gust_kmh=None, wind_kmh=kmh(9), items=ALL),
    case("missing-uv", uv=None, items=ALL),
    case("missing-hilo", hi=None, lo=None, items=ALL),
    case("missing-sun", sunrise=None, sunset=None, items=ALL),
    case("missing-hourly", hourly=None, items=ALL),
    case("missing-pops", hourly=hourly(pops=lambda i: None), items=ALL),
    case("missing-all-optional-pages", fl=None, hum=None, wdir=None, gust_kmh=None, uv=None, hi=None,
         lo=None, sunrise=None, sunset=None, hourly=None, layout="pages", items=ALL),

    # ---- no reading, single states ----
    case("no-reading-pages", reading=None, layout="pages", items=DEFAULT),
    case("no-reading-hybrid", reading=None, layout="hybrid", items=DEFAULT),
    case("hybrid-single-state", code=61, t=8.0, fl=6.0, layout="hybrid", items=("rain",)),
    case("pages-single-page", code=45, t=3.0, fl=1.0, layout="pages", items=("hilo", "rain")),
    case("anchor-no-details", code=2, items=()),

    # ---- the moon (showsMoon): a page, a ticker line, the icon it brings ----
    case("moon-pages-full-night", now=utc(2026, 9, 26, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None, layout="pages", items=("humidity", "moon")),
    case("moon-pages-first-quarter-day", now=utc(2026, 9, 18, 12, 0), code=2, t=15.0, fl=14.0,
         sunrise=None, sunset=None, hourly=None, layout="pages", items=("moon",)),
    case("moon-pages-waning-crescent", now=utc(2026, 10, 7, 3, 0), code=3, is_day=False, t=6.0, fl=4.0,
         sunrise=None, sunset=None, hourly=None, layout="pages", items=("feels", "moon")),
    case("moon-anchor-full-night", now=utc(2026, 9, 26, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None, items=("feels", "moon")),
    case("moon-anchor-waxing-gibbous-day", code=1, items=("feels", "moon", "hourly")),
    case("moon-anchor-only-line", now=utc(2026, 10, 3, 2, 0), code=3, is_day=False, t=5.0, fl=3.0,
         sunrise=None, sunset=None, hourly=None, items=("moon",)),
    case("moon-hybrid-full-night", now=utc(2026, 9, 26, 22, 0), code=0, is_day=False, t=9.0, fl=7.0,
         sunrise=None, sunset=None, hourly=None, layout="hybrid", items=("humidity", "moon")),
    case("moon-hybrid-last-quarter-day", now=utc(2026, 10, 3, 12, 0), code=0, t=18.0, fl=17.0,
         sunrise=None, sunset=None, hourly=None, layout="hybrid", items=("feels", "wind", "moon")),

    # ---- the budget: storm with every detail passes 480 frames → bursts ----
    case("over-budget-storm-all-hybrid", code=95, t=19.0, fl=16.0, hum=90, wind_kmh=kmh(17), wdir=270,
         gust_kmh=kmh(25), hi=21.0, lo=15.0, hourly=hourly(19, 3, pops(95)), layout="hybrid",
         items=ALL, every=10),
]

CASES_FRAMES = []   # the decoded frames, for the summary line
WIND_UNITS = {"m/s": "metresPerSecond", "km/h": "kilometresPerHour", "mph": "milesPerHour"}
SWITCHES = [("showsFeelsLike", "feels"), ("showsHumidity", "humidity"), ("showsWind", "wind"),
            ("showsHiLo", "hilo"), ("showsRainChance", "rain"), ("showsUV", "uv"),
            ("showsSunEvents", "sun"), ("showsMoon", "moon"), ("showsHourly", "hourly")]


def hexrows(grid):
    return ["".join("%02x%02x%02x" % (px or (0, 0, 0)) for px in row) for row in grid]


def frames_json(frames):
    return [{"ms": ms, "rows": hexrows(g)} for g, ms in frames]


def deflate(obj):
    """base64 of raw DEFLATE (wbits -15) of compact, key-sorted JSON."""
    raw = json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    return base64.b64encode(z.compress(raw) + z.flush()).decode()


def reading_json(r):
    if r is None:
        return None
    return {
        "code": r["code"], "isDay": r["is_day"], "temperature": r["t"], "apparentTemperature": r["fl"],
        "relativeHumidity": r["hum"], "windSpeed": r["wind_kmh"], "windDirection": r["wdir"],
        "windGusts": r["gust_kmh"], "uvIndex": r["uv"], "todayHigh": r["hi"], "todayLow": r["lo"],
        "sunrises": r["sunrise"], "sunsets": r["sunset"],
        "hourly": [list(h) for h in r["hourly"]] if r["hourly"] is not None else None,
    }


def config_json(c):
    out = {"layout": c["layout"], "changeEvery": c["every"],
           "units": "fahrenheit" if c["units"] == "f" else "celsius",
           "windUnit": WIND_UNITS[c["wind"]], "feelsLikeColour": c["feels_colour"]}
    for key, item in SWITCHES:
        out[key] = item in c["items"]
    return out


def icon_json(frames):
    palette = {(0, 0, 0): 0}
    out = []
    for grid, ms in frames:
        rows = []
        for row in grid:
            line = ""
            for px in row:
                c = px or (0, 0, 0)
                if c not in palette:
                    palette[c] = len(palette)
                line += DIGITS36[palette[c]]
            rows.append(line)
        out.append({"ms": ms, "rows": rows})
    if len(palette) > len(DIGITS36):
        raise SystemExit(f"{len(palette)} colours do not fit base 36")
    return {"palette": ["%02x%02x%02x" % c for c in palette], "frames": out}


def main():
    wgen = load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR)
    ids = [c["id"] for c in CASES]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate case ids")

    icons = {name: icon_json(wgen.icon_frames(name)) for name in sorted(wgen.all_icons())}
    with open(ICONS_OUT, "w") as f:
        json.dump({"icons": icons}, f, indent=1, sort_keys=True)
        f.write("\n")

    cases = []
    CASES_FRAMES.clear()
    for c in CASES:
        # BASE carries the switch-derived items in wgen's ORDER, as the tile does
        items = tuple(k for k in wgen.ORDER if k in c["items"])
        cfg = wgen.Config(layout=c["layout"], change_ms=c["every"] * 1000, units=c["units"],
                          wind_unit=c["wind"], feels_colour=c["feels_colour"], items=items)
        r = wgen.Reading(**c["reading"]) if c["reading"] is not None else None
        v = wgen.View(r, cfg, c["now"], timezone.utc)
        if c["layout"] == "anchor":
            tl = wgen.timeline(r, cfg, c["now"], timezone.utc)
            frames, burst = {"icon": frames_json(tl["icon"]), "area": frames_json(tl["area"])}, None
        else:
            full, burst = wgen.full_timeline(v)
            frames = {"full": frames_json(full)}
        CASES_FRAMES.append(frames)
        cases.append({"id": c["id"], "now": c["now"], "reading": reading_json(c["reading"]),
                      "config": config_json(c), "facts": v.facts, "burst": burst, "framesZ": deflate(frames)})

    glyphs = {"small": dict(sorted(wgen.G.items())), "big": dict(sorted(wgen.B.items()))}
    with open(FACE_OUT, "w", encoding="utf-8") as f:
        json.dump({"timeZone": "UTC", "width": wgen.W, "height": wgen.H, "areaX": wgen.AREA_X,
                   "glyphs": glyphs, "cases": cases}, f, indent=1, ensure_ascii=False)
        f.write("\n")
    total = sum(len(v) for c in CASES_FRAMES for v in c.values())
    print(f"{len(icons)} icons -> {ICONS_OUT}")
    print(f"{len(cases)} cases, {total} frames -> {FACE_OUT}")


if __name__ == "__main__":
    main()
