#!/usr/bin/env python3
"""TC002 (52x16) Better Weather face — the pixel source of truth.

Python computes every pixel: icons (icons.py), the big temperature, each
detail line, and the timelines each layout plays. The input is a `Reading`
as the app sees it (°C, km/h, epoch seconds; any field may be missing) and a
`Config` (the tile's settings); `timeline()` returns the frames the clock
shows, and `Scripts/make_weather_face_oracle.py` records them as the Swift
face's oracle.

Rounding is Python's `round()`: half to even. Float `%` is floored.

Run it to rebuild index.html, the browser mockup, from `CASES`.
"""
from __future__ import annotations

import base64, calendar, json, os, sys
from dataclasses import dataclass
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icons

W, H = 52, 16
HERE = os.path.dirname(os.path.abspath(__file__))
AREA_X, AREA_W = 18, 34           # right of the 16x16 icon and a 2 px gutter
LABEL = (0x60, 0x60, 0x60)
DIM = (0x40, 0x40, 0x40)
hexrgb = icons.hexrgb

# ---- small 5 px glyphs (the approved usage-face set + weather additions) ----
G = {
    "0": ["###", "#.#", "#.#", "#.#", "###"], "1": ["##.", ".#.", ".#.", ".#.", "###"],
    "2": ["###", "..#", "###", "#..", "###"], "3": ["###", "..#", "###", "..#", "###"],
    "4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "###", "..#", "###"],
    "6": ["###", "#..", "###", "#.#", "###"], "7": ["###", "..#", "..#", "..#", "..#"],
    "8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "###"],
    "%": ["#..", "..#", ".#.", "#..", "..#"], "-": ["...", "...", "###", "...", "..."],
    ":": [".", "#", ".", "#", "."], ".": [".", ".", ".", ".", "#"], " ": [".", ".", ".", ".", "."],
    "a": ["##.", "..#", ".##", "#.#", ".##"], "b": ["#..", "#..", "##.", "#.#", "##."],
    "c": [".##", "#..", "#..", "#..", ".##"], "d": ["..#", "..#", ".##", "#.#", ".##"],
    "e": [".#.", "#.#", "###", "#..", ".##"], "f": [".##", "#..", "###", "#..", "#.."],
    "g": [".##", "#.#", ".##", "..#", "##."], "l": ["#..", "#..", "#..", "#..", ".##"],
    "m": ["##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"], "n": ["##.", "#.#", "#.#", "#.#", "#.#"],
    "o": [".#.", "#.#", "#.#", "#.#", ".#."], "p": ["##.", "#.#", "##.", "#..", "#.."],
    "r": [".##", "#..", "#..", "#..", "#.."], "s": [".##", "#..", ".#.", "..#", "##."],
    "t": [".#.", "###", ".#.", ".#.", ".##"], "u": ["#.#", "#.#", "#.#", "#.#", ".##"],
    "v": ["#.#", "#.#", "#.#", "#.#", ".#."], "w": ["#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
    "y": ["#.#", "#.#", ".##", "..#", "##."], "q": [".##", "#.#", ".##", "..#", "..#"],
    # additions for weather
    "h": ["#..", "#..", "##.", "#.#", "#.#"], "i": ["#", ".", "#", "#", "#"],
    "k": ["#..", "#.#", "##.", "#.#", "#.#"], "z": ["###", "..#", ".#.", "#..", "###"],
    "x": ["#.#", "#.#", ".#.", "#.#", "#.#"],
    "°": [".#.", "#.#", ".#.", "...", "..."], "/": ["..#", "..#", ".#.", "#..", "#.."],
    "↑": [".#.", "###", ".#.", ".#.", ".#."], "↓": [".#.", ".#.", ".#.", "###", ".#."],
    # wind arrows point where the air GOES (Open-Meteo gives where it comes FROM)
    "⇑": ["..#..", ".###.", "#.#.#", "..#..", "..#.."],
    "⇓": ["..#..", "..#..", "#.#.#", ".###.", "..#.."],
    "⇒": ["..#..", "...#.", "#####", "...#.", "..#.."],
    "⇐": ["..#..", ".#...", "#####", ".#...", "..#.."],
    "⇗": ["..###", "...##", "..#.#", ".#...", "#...."],
    "⇖": ["###..", "##...", "#.#..", "...#.", "....#"],
    "⇘": ["#....", ".#...", "..#.#", "...##", "..###"],
    "⇙": ["....#", "...#.", "#.#..", "##...", "###.."],
    "☀": ["..#..", ".###.", "#####", "..#..", "....."],   # tiny sunrise mark
}

# ---- big 5x9 digits for the temperature -------------------------------------
B = {
    "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "3": [".###.", "#...#", "....#", "....#", "..##.", "....#", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#..#.", "#####", "...#.", "...#.", "...#."],
    "5": ["#####", "#....", "#....", "####.", "....#", "....#", "....#", "#...#", ".###."],
    "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "....#", "...#.", "..#..", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", "#...#", ".###.", "#...#", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", "#...#", ".####", "....#", "....#", "....#", ".###."],
    "-": ["...", "...", "...", "...", "###", "...", "...", "...", "..."],
    "°": [".#.", "#.#", ".#.", "...", "...", "...", "...", "...", "..."],
    "%": ["##..#", "##..#", "...#.", "...#.", "..#..", ".#...", ".#...", "#..##", "#..##"],
}


def width(s, font=G):
    return sum(len(font[ch][0]) + 1 for ch in s) - 1 if s else 0


class Area:
    """A w x h block of pixels, None = unlit."""
    def __init__(self, w=AREA_W, h=H):
        self.w, self.h = w, h
        self.px = [[None] * w for _ in range(h)]

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def text(self, s, x, y, c, font=G):
        for ch in s:
            for dy, row in enumerate(font[ch]):
                for dx, v in enumerate(row):
                    if v == "#":
                        self.put(x + dx, y + dy, c)
            x += len(font[ch][0]) + 1
        return x

    def runs(self, x, y, parts):
        """parts: [(text, colour, font)] left to right. A grey label is
        followed by 3 blank px (the usage face's label/value rule), anything
        else by 2."""
        for p in parts:
            s, c, font = p[:3]
            x = self.text(s, x, y, c, font) - 1 + (gap_after(p) if s else 1)
        return x

    def rows(self):
        return ["".join("%02x%02x%02x" % c if c else "000000" for c in r) for r in self.px]


# ---- colours -----------------------------------------------------------------

STOPS = [(-20, "#3333FF"), (-10, "#3388FF"), (0, "#33E5FF"), (7, "#33FFCC"),
         (14, "#33FF33"), (21, "#FFFF33"), (28, "#FF9933"), (35, "#FF2200")]


def temp_colour(celsius):
    """TemperatureColour from the app: linear between stops, clamped."""
    pts = [(t, hexrgb(h)) for t, h in STOPS]
    if celsius <= pts[0][0]:
        return pts[0][1]
    for (t0, c0), (t1, c1) in zip(pts, pts[1:]):
        if celsius <= t1:
            k = (celsius - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
    return pts[-1][1]


def wind_colour(ms):
    for lim, h in ((3, "#CFE8F0"), (8, "#7CFC9A"), (14, "#FFD24A"), (20, "#FF8C1A")):
        if ms < lim:
            return hexrgb(h)
    return hexrgb("#FF3B30")


def uv_colour(uv):
    for lim, h in ((3, "#3EC43E"), (6, "#FFD24A"), (8, "#FF8C1A"), (11, "#FF3B30")):
        if uv < lim:
            return hexrgb(h)
    return hexrgb("#B45AFF")


HUM = hexrgb("#4DA6FF")
RAINC = hexrgb("#4DA6FF")
RAIN_CAP = hexrgb("#D8F0FF")
SUNC = hexrgb("#FFB52E")
WHITE = hexrgb("#E8E8E8")
MOONC = hexrgb("#F4EBB8")

# the moon's phases by index (moon_index): the two-line page name, the ticker noun
MOON_NAMES = [("new", "moon"), ("waxing", "crescent"), ("first", "quarter"), ("waxing", "gibbous"),
              ("full", "moon"), ("waning", "gibbous"), ("last", "quarter"), ("waning", "crescent")]
MOON_NOUNS = ["new", "crescent", "quarter", "gibbous", "full", "gibbous", "quarter", "crescent"]


def arrow(from_deg):
    to = (from_deg + 180) % 360
    return "⇑⇗⇒⇘⇓⇙⇐⇖"[round(to / 45) % 8]


# ---- the input: a reading as the app sees it ------------------------------------

@dataclass(frozen=True)
class Reading:
    """One Open-Meteo answer. Temperatures °C, wind km/h, times epoch seconds.
    A missing reading is `None`, not a Reading; a missing field is `None`."""
    code: int | None = None
    is_day: bool | None = None
    t: float | None = None           # air
    fl: float | None = None          # felt
    hum: float | None = None         # relative humidity, %
    wind_kmh: float | None = None
    wdir: float | None = None        # degrees the wind comes FROM
    gust_kmh: float | None = None
    uv: float | None = None
    hi: float | None = None          # today's daily max
    lo: float | None = None          # today's daily min
    sunrise: list | None = None      # [today, tomorrow]
    sunset: list | None = None       # [today, tomorrow]
    hourly: list | None = None       # [(epoch, temp_c, pop or None)]


ORDER = ["feels", "humidity", "wind", "hilo", "rain", "uv", "sun", "moon", "hourly"]
DEFAULT_ITEMS = ("feels", "humidity", "wind", "hilo", "rain", "hourly")


@dataclass(frozen=True)
class Config:
    """The tile's settings. `items` are the enabled detail keys, in order;
    "moon" among them is the tile's showsMoon, which also owns the clear
    night's icon."""
    layout: str = "anchor"           # anchor | pages | hybrid
    change_ms: int = 10000
    units: str = "c"                 # c | f
    wind_unit: str = "m/s"           # m/s | km/h | mph
    feels_colour: bool = True
    items: tuple = DEFAULT_ITEMS


# ---- units -----------------------------------------------------------------------

WIND_DIV = {"m/s": 3.6, "km/h": 1.0, "mph": 1.609344}   # km/h -> unit


def disp_temp(c, units):
    """°C in, the whole number the face prints in `units`."""
    return round(c * 9 / 5 + 32) if units == "f" else round(c)


def mps(kmh):
    """Every wind threshold and colour is in m/s, unrounded."""
    return kmh / 3.6


def disp_wind(kmh, unit):
    return round(kmh / WIND_DIV[unit])


# ---- facts derived from a reading ---------------------------------------------------

NEW_MOON = 947182440            # 2000-01-06 18:14 UTC
SYNODIC_DAYS = 29.530588853


def moon_index(now):
    """0 new, 2 first quarter, 4 full, 6 last quarter."""
    age = ((now - NEW_MOON) / 86400.0 % SYNODIC_DAYS) / SYNODIC_DAYS
    return round(age * 8) % 8


def hour_start(now, tz):
    """The epoch the hour containing `now` starts at, on the clock of `tz`."""
    d = datetime.fromtimestamp(now, tz).replace(minute=0, second=0, microsecond=0)
    return int(d.timestamp())


def next_hours(r, now, tz):
    """The hourly entries of the current hour and the next ten, by time."""
    if r is None or not r.hourly:
        return []
    start = hour_start(now, tz)
    return sorted((h for h in r.hourly if start <= h[0] < start + 11 * 3600), key=lambda h: h[0])


def rain_chance(r, now, tz):
    """The highest precipitation probability over the current hour and the next two."""
    if r is None or not r.hourly:
        return None
    start = hour_start(now, tz)
    pops = [h[2] for h in r.hourly if start <= h[0] < start + 3 * 3600 and h[2] is not None]
    return max(pops) if pops else None


def next_sun(r, now):
    """("rise"|"set", epoch): today's sunrise if still ahead, else today's
    sunset if still ahead, else tomorrow's sunrise."""
    if r is None:
        return None
    rises, sets = r.sunrise or [], r.sunset or []
    if len(rises) > 0 and rises[0] is not None and now < rises[0]:
        return ("rise", rises[0])
    if len(sets) > 0 and sets[0] is not None and now < sets[0]:
        return ("set", sets[0])
    if len(rises) > 1 and rises[1] is not None and now < rises[1]:
        return ("rise", rises[1])
    return None


def clock_text(epoch, tz):
    """H:MM, no leading zero on the hour."""
    d = datetime.fromtimestamp(epoch, tz)
    return "%d:%02d" % (d.hour, d.minute)


def select_icon(r, now, moon=False):
    """Spec §4.1, first match wins. A clear night is the moon in its phase
    when the tile shows the moon (`moon`), else the plain clear night."""
    if r is None:
        return "nodata"
    code = r.code if r.code is not None else 0
    day = r.is_day is not False
    t = r.t
    w = mps(r.wind_kmh) if r.wind_kmh is not None else 0.0
    g = mps(r.gust_kmh) if r.gust_kmh is not None else None
    windy = w >= 10 or (g is not None and g >= 15)
    dn = lambda d, n: d if day else n
    if code in (96, 99):
        return "hail"
    if code == 95:
        return "storm" if w >= 14 or (g is not None and g >= 20) else "thunder"
    if code in (71, 73, 75, 77, 85, 86):
        if windy:
            return "blizzard"
        if code in (85, 86):
            return dn("snowShowersDay", "snowShowersNight")
        return "snow"
    if code in (56, 57, 66, 67):
        return "freezingRain"
    if code in (51, 53, 55, 61, 63, 65, 80, 81, 82):
        if t is not None and 0 <= t <= 2:
            return "sleet"
        if code in (51, 53, 55):
            return "drizzle"
        if code in (61, 63):
            return "rain"
        if code in (65, 82):
            return "heavyRain"
        return dn("showersDay", "showersNight")
    if code == 45:
        return "fog"
    if code == 48:
        return "rimeFog"
    if code not in (0, 1, 2, 3):
        code = 0                                  # the existing clear fallback
    if windy:
        return "cloudWindy" if code == 3 else dn("windyDay", "windyNight")
    if code in (0, 1) and day and t is not None:
        if t >= 30:
            return "hot"
        if t <= -10:
            return "frostyClear"
    if code == 0:
        if day:
            return "clearDay"
        return "moon%d" % moon_index(now) if moon else "clearNight"
    if code == 1:
        return dn("mainlyClearDay", "mainlyClearNight")
    if code == 2:
        return dn("partlyCloudyDay", "partlyCloudyNight")
    return dn("cloudDay", "cloudNight")


def facts(r, cfg, now, tz):
    """What the face derives from a reading before drawing anything."""
    sun = next_sun(r, now)
    return {
        "icon": select_icon(r, now, "moon" in cfg.items),
        "moon": moon_index(now),
        "sun": {"event": sun[0], "at": sun[1], "text": clock_text(sun[1], tz)} if sun else None,
        "rain": rain_chance(r, now, tz),
        "arrow": arrow(r.wdir) if r is not None and r.wdir is not None else None,
        "hours": [h[0] for h in next_hours(r, now, tz)],
    }


class View:
    """A reading, the tile's settings and the facts: everything a piece draws from."""
    def __init__(self, r, cfg, now, tz):
        self.r, self.cfg, self.now, self.tz = r, cfg, now, tz
        self.facts = facts(r, cfg, now, tz)
        self.icon = self.facts["icon"]
        self.hours = next_hours(r, now, tz)

    def deg(self, c):
        return "%d°" % disp_temp(c, self.cfg.units)

    def num(self, c):
        return "%d" % disp_temp(c, self.cfg.units)

    def gusty(self):
        r = self.r
        return r.gust_kmh is not None and mps(r.gust_kmh) - mps(r.wind_kmh) >= 5


# ---- pieces -------------------------------------------------------------------

def big_temp(v, feels_colour, h=9):
    a = Area(AREA_W, h)
    r = v.r
    if r is None:
        a.text("--°", 0, 0, DIM, B)
        return a
    ink = temp_colour(r.fl if feels_colour and r.fl is not None else r.t)
    x = a.text(v.deg(r.t), 0, 0, ink, B)
    unit = v.cfg.units
    if x + 1 + width(unit) <= AREA_W:
        a.text(unit, x + 1, 4, LABEL)
    return a


def line(parts):
    a = Area(AREA_W, 5)
    a.runs(0, 0, parts)
    return a


def hilo_parts(v):
    """Today's high and low; the degree signs go first when both do not fit."""
    r = v.r
    for d in (v.deg, v.num):
        parts = [("↑", LABEL, G, 1), (d(r.hi), temp_colour(r.hi), G, 3),
                 ("↓", LABEL, G, 1), (d(r.lo), temp_colour(r.lo), G)]
        if parts_width(parts) <= AREA_W:
            return parts
    return parts


def gap_after(p):
    """Blank px after a part: explicit 4th item, else 3 after a grey word
    label (the usage face's rule), 2 after a value. Arrows are marks: 1."""
    if len(p) > 3:
        return p[3]
    return 3 if p[1] == LABEL else 2


def parts_width(parts):
    return sum(width(p[0]) + gap_after(p) for p in parts) - gap_after(parts[-1])


def wind_parts(v):
    r, unit = v.r, v.cfg.wind_unit
    wc = wind_colour(mps(r.wind_kmh))
    wtext = "%d" % disp_wind(r.wind_kmh, unit)
    parts = [(arrow(r.wdir), wc, G, 2)]
    if v.gusty():
        parts += [(wtext, wc, G), ("g", LABEL, G, 1),
                  ("%d" % disp_wind(r.gust_kmh, unit), wind_colour(mps(r.gust_kmh)), G)]
    else:
        parts += [(wtext + " " + unit, wc, G)]
    return parts


def detail_lines(v):
    """Every detail the ticker can show for this reading, in ORDER, keyed by
    the tile setting that owns it. A detail whose data is missing is absent."""
    r, f = v.r, v.facts
    if r is None:
        return {"nodata": line([("no data", DIM, G)])}
    out = {}
    if r.fl is not None:
        out["feels"] = line([("fl", LABEL, G), (v.deg(r.fl), temp_colour(r.fl), G)])
    if r.hum is not None:
        out["humidity"] = line([("h", LABEL, G), ("%d%%" % round(r.hum), HUM, G)])
    if r.wind_kmh is not None and r.wdir is not None:
        out["wind"] = line(wind_parts(v))
    if r.hi is not None and r.lo is not None:
        out["hilo"] = line(hilo_parts(v))
    if f["rain"] is not None:
        pop = f["rain"]
        out["rain"] = line([("rain", LABEL, G), ("%d%%" % pop, RAINC if pop >= 30 else LABEL, G)])
    if r.uv is not None:
        uv = round(r.uv)
        out["uv"] = line([("uv", LABEL, G), ("%d" % uv, uv_colour(uv), G)])
    if f["sun"] is not None:
        out["sun"] = line([(f["sun"]["event"], LABEL, G), (f["sun"]["text"], SUNC, G)])
    if "moon" in v.cfg.items:   # a date fact: there by day and by night
        out["moon"] = line([(MOON_NOUNS[f["moon"]], MOONC, G)])
    if v.hours:
        out["hourly"] = hourly_chart(v)
    return out


def hourly_chart(v):
    """11 bars (2 px + 1 gap) of the next hours, height by temperature within
    those hours' range, colour by temperature; a pale cap where rain is likely."""
    a = Area(AREA_W, 5)
    temps = [h[1] for h in v.hours]
    lo, hi = min(temps), max(temps)
    for i, (_, t, pop) in enumerate(v.hours):
        hgt = 1 + round((t - lo) / (hi - lo) * 3) if hi > lo else 2
        x = i * 3
        c = temp_colour(t)
        for y in range(5 - hgt, 5):
            a.put(x, y, c)
            a.put(x + 1, y, c)
        if pop is not None and pop >= 50:
            a.put(x, 4 - hgt, RAIN_CAP)
            a.put(x + 1, 4 - hgt, RAIN_CAP)
    return a


def big_page(value_text, value_colour, label_parts, font=B):
    a = Area()
    a.text(value_text, 0, 0, value_colour, font)
    a.runs(0, 11, label_parts)
    return a


def item_icon(v, key):
    """Hybrid: the icon a ticker line brings with it; None keeps the weather's."""
    r = v.r
    if r is None:
        return None
    if key == "feels":
        return "feelsWarm" if r.fl >= 10 else "feelsCold"
    if key == "sun":
        return "sunrise" if v.facts["sun"]["event"] == "rise" else "sunset"
    if key == "moon":
        return "moon%d" % v.facts["moon"]
    return {"humidity": "humidity", "wind": "wind", "rain": "umbrella", "uv": "uv"}.get(key)


def pages(v, feels_colour):
    """Layout B: [(key, icon, Area 34x16)] — each page its own icon, one big
    figure and a label. The temperature page always; the others by data."""
    r, units = v.r, v.cfg.units
    if r is None:
        return [("temp", "nodata", big_page("--°", DIM, [("no data", DIM, G)]))]
    out = []
    top = big_temp(v, feels_colour)
    full = Area()
    for y in range(9):
        full.px[y] = top.px[y][:]
    if r.hi is not None and r.lo is not None:
        full.runs(0, 11, hilo_parts(v))
    out.append(("temp", v.icon, full))
    if r.fl is not None:
        fp = big_page(v.deg(r.fl), temp_colour(r.fl), [("feels", LABEL, G)])
        ux = width(v.deg(r.fl), B) + 1
        if ux + width(units) <= AREA_W:
            fp.text(units, ux, 4, LABEL)   # a temperature always names its scale
        out.append(("feels", "feelsWarm" if r.fl >= 10 else "feelsCold", fp))
    if r.hum is not None:
        out.append(("humidity", "humidity", big_page("%d%%" % round(r.hum), HUM, [("humidity", LABEL, G)])))
    if r.wind_kmh is not None and r.wdir is not None:
        wp = Area()
        wc = wind_colour(mps(r.wind_kmh))
        x = wp.text("%d" % disp_wind(r.wind_kmh, v.cfg.wind_unit), 0, 0, wc, B)
        wp.text(v.cfg.wind_unit, x + 2, 4, LABEL)
        gust = [("g", LABEL, G, 1), ("%d" % disp_wind(r.gust_kmh, v.cfg.wind_unit),
                                     wind_colour(mps(r.gust_kmh)), G)] if v.gusty() else []
        wp.runs(0, 11, [(arrow(r.wdir), wc, G)] + gust)
        out.append(("wind", "wind", wp))
    if "moon" in v.cfg.items:
        mp = Area()
        first, second = MOON_NAMES[v.facts["moon"]]
        mp.text(first, 0, 2, MOONC)
        mp.text(second, 0, 9, MOONC)
        out.append(("moon", "moon%d" % v.facts["moon"], mp))
    return out


def nodata_icon():
    f = icons.blank()
    icons.cloud(f, 0, 4, "nt")
    return [(f, 1000)]


def all_icons():
    """Every approved animation by name, plus nodata."""
    return {**icons.THEMES, **icons.DERIVED, **icons.MOON, **icons.PAGE_ICONS, "nodata": nodata_icon}


_ICON_CACHE = {}


def icon_frames(name):
    if name not in _ICON_CACHE:
        _ICON_CACHE[name] = all_icons()[name]()
    return _ICON_CACHE[name]


# ---- timelines ------------------------------------------------------------------
# A state is one detail on screen for `change_ms`, then the change to the next.

STEP_MS, SLIDE = 60, 6            # ticker: 1 row per step; 5 rows + 1 blank
ICON_STEP = 3                     # Hybrid: the icon slides 3 rows per ticker step
PAGE_STEP_MS, PAGE_STEPS = 40, 8  # Pages: the whole panel slides 2 rows per step
STILL_MS = 1000                   # Anchor's area with a single state
MAX_FRAMES, MAX_BASE64 = 480, 136_000
BURST_MS = 2000


def ticker_keys(v):
    lines = detail_lines(v)
    if "nodata" in lines:
        return ["nodata"], lines
    return [k for k in v.cfg.items if k in lines], lines


def area_timeline(v, hybrid=False):
    """The right 34x16: temperature fixed on rows 0-8, ticker on rows 11-15.
    Returns [(grid, ms, icon)] — icon is the weather's, or in Hybrid the one
    the line brings. Each state: its dwell frame, then SLIDE-1 slide steps."""
    top = big_temp(v, v.cfg.feels_colour).px
    keys, lines = ticker_keys(v)
    ticker = [lines[k].px for k in keys]

    def icon_of(key):
        return (item_icon(v, key) if hybrid else None) or v.icon

    def frame(cur, nxt, k):
        g = [[None] * AREA_W for _ in range(H)]
        for y in range(9):
            g[y] = top[y][:]
        for r in range(5):
            src = r + k
            row = cur[src] if src < 5 else (nxt[src - 6] if 6 <= src < 11 else None)
            if row:
                g[11 + r] = row[:]
        return g

    if len(ticker) < 2:
        empty = [[None] * AREA_W] * 5
        g = frame(ticker[0], ticker[0], 0) if ticker else frame(empty, empty, 0)
        return [(g, STILL_MS, icon_of(keys[0]) if keys else v.icon)]
    out = []
    for i, cur in enumerate(ticker):
        nxt = ticker[(i + 1) % len(ticker)]
        out.append((frame(cur, nxt, 0), v.cfg.change_ms, icon_of(keys[i])))
        for k in range(1, SLIDE):
            out.append((frame(cur, nxt, k), STEP_MS, icon_of(keys[i])))
    return out


def play(tl, total, burst):
    """An icon over `total` ms: whole loops until at least `burst` ms have
    played, then its first frame holds for the rest (burst=None: loop all)."""
    out, t, i = [], 0, 0
    while t < total:
        if burst is not None and t >= burst and i % len(tl) == 0:
            out.append((tl[0][0], total - t))
            break
        f, ms = tl[i % len(tl)]
        ms = min(ms, total - t)
        if ms < 20 and out:
            out[-1] = (out[-1][0], out[-1][1] + ms)
        else:
            out.append((f, ms))
        t += ms
        i += 1
    return out


def loop_ms(tl):
    return sum(ms for _, ms in tl)


def compose(icon_rows, area_rows):
    g = [[None] * W for _ in range(H)]
    for y in range(H):
        g[y][:16] = icon_rows[y][:]
        g[y][AREA_X:] = area_rows[y][:]
    return g


def pages_full(v, burst=None):
    """Layout B as ONE 52x16 timeline: during a dwell the icon animates beside
    a still page; on a change the WHOLE page — icon and figure together —
    slides up 2 rows per step, so the icon can never lead or trail its text.
    A single page is a still dwell: its icon plays one whole loop."""
    pg = [p for p in pages(v, v.cfg.feels_colour) if p[0] == "temp" or p[0] in v.cfg.items]
    if len(pg) == 1:
        _, name, area = pg[0]
        tl = icon_frames(name)
        return [(compose(f, area.px), d) for f, d in play(tl, loop_ms(tl), burst)]
    out = []
    for i, (_, name, area) in enumerate(pg):
        seq = play(icon_frames(name), v.cfg.change_ms, burst)
        out += [(compose(f, area.px), d) for f, d in seq]
        _, nxt_name, nxt_area = pg[(i + 1) % len(pg)]
        cur_full = compose(seq[-1][0], area.px)
        nxt_full = compose(icon_frames(nxt_name)[0][0], nxt_area.px)
        for k in range(1, PAGE_STEPS + 1):
            g = []
            for r in range(H):
                src = r + 2 * k
                g.append(cur_full[src][:] if src < H else
                         (nxt_full[src - 18][:] if 18 <= src < 34 else [None] * W))
            out.append((g, PAGE_STEP_MS))
    return out


def hybrid_full(v, burst=None):
    """Hybrid as ONE 52x16 timeline. The temperature never moves; on a change
    the ticker line slides up 1 row per step and the icon beside it slides up
    3 rows per step over the SAME steps — both land together. A single state
    is a still dwell: its icon plays one whole loop."""
    tagged = area_timeline(v, hybrid=True)
    if len(tagged) == 1:
        area, _, name = tagged[0]
        tl = icon_frames(name)
        return [(compose(f, area), d) for f, d in play(tl, loop_ms(tl), burst)]
    out = []
    n = len(tagged) // SLIDE
    for i in range(n):
        area, ms, name = tagged[i * SLIDE]
        seq = play(icon_frames(name), ms, burst)
        out += [(compose(f, area), d) for f, d in seq]
        last = seq[-1][0]
        nxt = icon_frames(tagged[((i + 1) % n) * SLIDE][2])[0][0]
        for k, (sarea, sms, _) in enumerate(tagged[i * SLIDE + 1:(i + 1) * SLIDE], 1):
            shift = ICON_STEP * k
            ic = []
            for y in range(16):
                src = y + shift
                ic.append(last[src] if src < 16 else (nxt[src - 18] if 18 <= src < 34 else [None] * 16))
            out.append((compose(ic, sarea), sms))
    return out


def fits(frames):
    """The measured ceilings of one animated image on the TC002."""
    if len(frames) > MAX_FRAMES:
        return False
    return len(base64.b64encode(gif(frames, W, H))) <= MAX_BASE64


def full_timeline(v):
    """Pages / Hybrid: (frames, burst). Icons loop through every dwell unless
    that passes a ceiling; then each plays whole loops for BURST_MS and rests."""
    build = pages_full if v.cfg.layout == "pages" else hybrid_full
    frames = build(v, None)
    if fits(frames):
        return frames, None
    return build(v, BURST_MS), BURST_MS


def timeline(r, cfg, now, tz):
    """Anchor: {"icon": the weather icon's own loop, "area": the 34x16 right
    area}; Pages / Hybrid: {"full": one 52x16 timeline}. Frames are
    (grid, ms), a grid rows of RGB tuples or None (unlit)."""
    v = View(r, cfg, now, tz)
    if cfg.layout == "anchor":
        return {"icon": icon_frames(v.icon), "area": [(g, ms) for g, ms, _ in area_timeline(v)]}
    return {"full": full_timeline(v)[0]}


# ---- GIF: full frames, one global palette ------------------------------------

def lzw_encode(pixels):
    out, buf, cnt = [], 0, 0

    def emit(code, width):
        nonlocal buf, cnt
        buf |= code << cnt
        cnt += width
        while cnt >= 8:
            out.append(buf & 0xFF)
            buf >>= 8
            cnt -= 8

    width, table, phrase = 9, {bytes([i]): i for i in range(256)}, b""
    emit(256, width)
    for p in pixels:
        nxt = phrase + bytes([p])
        if nxt in table:
            phrase = nxt
            continue
        emit(table[phrase], width)
        code = len(table) + 2
        table[nxt] = code
        if code == 1 << width and width < 12:
            width += 1
        phrase = bytes([p])
    if phrase:
        emit(table[phrase], width)
    emit(257, width)
    if cnt:
        out.append(buf & 0xFF)
    return bytes(out)


def gif(frames, w, h):
    """frames: [(grid[h][w] of RGB|None, ms)] -> GIF89a, full frames, one palette."""
    palette, indexed = {(0, 0, 0): 0}, []
    for grid, ms in frames:
        row = bytearray()
        for y in range(h):
            for x in range(w):
                c = grid[y][x] or (0, 0, 0)
                if c not in palette:
                    palette[c] = len(palette)
                row.append(palette[c])
        indexed.append((bytes(row), max(2, round(ms / 10))))
    if len(palette) > 256:
        raise ValueError(f"{len(palette)} colours > 256")
    colours = list(palette)
    g = bytearray(b"GIF89a") + bytes([w, 0, h, 0, 0xF7, 0, 0])
    for i in range(256):
        g += bytes(colours[i]) if i < len(colours) else b"\0\0\0"
    g += bytes([0x21, 0xFF, 11]) + b"NETSCAPE2.0" + bytes([3, 1, 0, 0, 0])
    for data, cs in indexed:
        g += bytes([0x21, 0xF9, 4, 0x04, cs & 0xFF, cs >> 8, 0, 0])
        g += bytes([0x2C, 0, 0, 0, 0, w, 0, h, 0, 0, 8])
        blob = lzw_encode(data)
        for i in range(0, len(blob), 255):
            g += bytes([len(blob[i:i + 255])]) + blob[i:i + 255]
        g.append(0)
    g.append(0x3B)
    return bytes(g)


# ---- mockup scenarios ------------------------------------------------------------
# Readings as the app would receive them. A scenario is written in the units
# it is shown in (as the approved mockups were); `S` converts to °C / km/h /
# epochs. "set HH:MM" scenarios are at 12:00 UTC, "rise" ones at 23:30.

DAY0 = calendar.timegm((2026, 9, 23, 0, 0, 0))


def _hm(day, hm):
    h, m = hm.split(":")
    return day + int(h) * 3600 + int(m) * 60


def hours(a, b, bump=0, rain=()):
    """11 hourly points easing from a to b with a mid bump; rain = indexes with pop>=50."""
    pts = []
    for i in range(11):
        k = i / 10
        pts.append((a + (b - a) * k + bump * (1 - abs(2 * k - 1)), i in rain))
    return pts


def S(id, desc, code, is_day, t, fl, hum, wind, wdir, gust, hi, lo, pop, uv, sun, hourly,
      units="c", wunit="m/s", day=DAY0):
    to_c = (lambda v: (v - 32) * 5 / 9) if units == "f" else (lambda v: v)
    kmh = lambda v: round(v * WIND_DIV[wunit], 1)
    ev, at = sun
    if ev == "set":
        now = day + 12 * 3600
        rises, sets = [_hm(day, "6:30"), _hm(day + 86400, "6:31")], [_hm(day, at), _hm(day + 86400, at)]
    else:
        now = day + 23 * 3600 + 30 * 60
        rises, sets = [_hm(day, "6:40"), _hm(day + 86400, at)], [_hm(day, "18:50"), _hm(day + 86400, "18:48")]
    start = now - now % 3600
    hourly_ = []
    for i, (temp, wet) in enumerate(hourly):
        p = 60 if wet else 0
        if i < 3:   # the rain window carries the scenario's chance where the chart agrees
            p = pop if (pop >= 50) == wet else (60 if wet else min(pop, 49))
        hourly_.append((start + i * 3600, to_c(temp), p))
    r = Reading(code=code, is_day=is_day, t=to_c(t), fl=to_c(fl), hum=hum, wind_kmh=kmh(wind), wdir=wdir,
                gust_kmh=kmh(gust), uv=uv, hi=to_c(hi), lo=to_c(lo), sunrise=rises, sunset=sets, hourly=hourly_)
    return dict(id=id, desc=desc, now=now, reading=r, units=units, wunit=wunit)


CASES = [
    S("01-clear-day", "ясно днём, тепло, UV высокий", 0, True, 24, 26, 38, 3, 225, 5, 27, 15, 0, 7, ("set", "19:42"), hours(24, 18, 3)),
    S("02-clear-night", "ясная ночь, штиль — луна в текущей фазе", 0, False, 12, 11, 71, 1, 90, 2, 22, 9, 5, 0, ("rise", "6:48"), hours(12, 9, -1)),
    S("03-partly-day", "переменная облачность днём", 2, True, 8, 5, 64, 6, 300, 9, 11, 3, 20, 3, ("set", "18:57"), hours(8, 5, 2)),
    S("04-partly-night", "переменная облачность ночью", 2, False, 6, 3, 80, 4, 270, 7, 9, 2, 10, 0, ("rise", "7:02"), hours(6, 3)),
    S("05-overcast", "пасмурно, около нуля", 3, True, -1, -6, 86, 7, 0, 12, 1, -3, 40, 1, ("set", "17:31"), hours(-1, -3, 1, (8, 9, 10))),
    S("06-overcast-night", "пасмурная ночь", 3, False, 2, -1, 90, 3, 200, 5, 4, 0, 30, 0, ("rise", "8:15"), hours(2, 0)),
    S("07-fog", "туман, влажность 100%", 45, True, 3, 1, 100, 1, 160, 2, 7, 1, 10, 0, ("set", "17:05"), hours(3, 6, 1)),
    S("08-drizzle", "морось", 53, True, 9, 7, 93, 4, 250, 7, 11, 7, 60, 1, ("set", "18:20"), hours(9, 8, 1, (0, 1, 2, 3))),
    S("09-rain", "дождь, вероятность 90%", 63, True, 14, 13, 95, 8, 210, 14, 16, 11, 90, 1, ("set", "19:10"), hours(14, 12, 0, (0, 1, 2, 3, 4, 5))),
    S("10-snow-feels", "снег −12°, ощущается −19° (цвет по ощущаемой)", 73, True, -12, -19, 85, 5, 20, 9, -9, -15, 80, 0, ("set", "16:48"), hours(-12, -15, 1, (0, 1, 2, 3, 4))),
    S("11-freezing", "ледяной дождь / гололёд", 66, True, -3, -8, 92, 6, 45, 10, -1, -5, 70, 0, ("set", "17:12"), hours(-3, -5, 0, (2, 3, 4, 5))),
    S("12-thunder", "гроза, душно", 95, True, 22, 25, 78, 6, 180, 15, 28, 18, 70, 5, ("set", "20:14"), hours(22, 19, 4, (3, 4, 5, 6))),
    S("13-storm", "шторм: ветер 17 м/с, порывы 25", 95, True, 19, 16, 90, 17, 270, 25, 21, 15, 95, 2, ("set", "20:02"), hours(19, 16, 0, tuple(range(11)))),
    S("14-extreme-cold", "экстрим −35°, ощущается −44° — морозное солнце", 0, True, -35, -44, 60, 4, 0, 6, -30, -38, 0, 1, ("set", "15:40"), hours(-35, -38, 3)),
    S("15-fahrenheit", "°F и mph: 104°f, трёхзначная ширина — жара", 0, True, 104, 111, 20, 9, 120, 15, 106, 82, 0, 11, ("set", "20:30"), hours(104, 90, 4), "f", "mph"),
    S("17-windy", "ясно, но ветер 12 м/с — иконка «ветрено» вместо солнца", 0, True, 11, 6, 45, 12, 290, 19, 13, 6, 0, 3, ("set", "18:40"), hours(11, 8, 1)),
    S("18-heat", "жара 36° — иконка «жара»", 0, True, 36, 39, 25, 2, 150, 4, 38, 24, 0, 10, ("set", "21:05"), hours(36, 28, 2)),
    S("19-showers", "ливень с прояснениями (WMO 80–81)", 80, True, 17, 16, 82, 5, 230, 11, 20, 13, 60, 4, ("set", "19:55"), hours(17, 15, 1, (1, 2, 6, 7))),
    S("20-moon", "ясная ночь — луна в текущей фазе (растущая)", 0, False, 9, 7, 76, 2, 60, 3, 16, 6, 0, 0, ("rise", "6:55"), hours(9, 6), day=DAY0 - 5 * 86400),
    dict(id="16-no-data", desc="нет данных (сеть/место не задано)", now=DAY0 + 12 * 3600, reading=None, units="c", wunit="m/s"),
]


def case_config(sc, **kw):
    return Config(units=sc["units"], wind_unit=sc["wunit"], **kw)


# Gallery groups: (title, [(icon, trigger)]) — the trigger is what selects it.
GROUPS = [
    ("По коду WMO (Open-Meteo weather_code)", [
        ("clearDay", "0 · день"), ("clearNight", "0 · ночь"),
        ("moon4", "0 · ночь + «фаза луны» → луна в текущей фазе"),
        ("mainlyClearDay", "1 · день"), ("mainlyClearNight", "1 · ночь"),
        ("partlyCloudyDay", "2 · день"), ("partlyCloudyNight", "2 · ночь"),
        ("cloudDay", "3 · день"), ("cloudNight", "3 · ночь"),
        ("fog", "45 туман"), ("rimeFog", "48 изморозевый туман"),
        ("drizzle", "51 53 55 морось"), ("freezingRain", "56 57 66 67 ледяной дождь"),
        ("rain", "61 63 дождь"), ("heavyRain", "65 82 сильный дождь"),
        ("showersDay", "80 81 ливень · день"), ("showersNight", "80 81 ливень · ночь"),
        ("snow", "71 73 75 77 снег"), ("snowShowersDay", "85 86 снежный заряд · день"),
        ("snowShowersNight", "85 86 снежный заряд · ночь"),
        ("thunder", "95 гроза"), ("storm", "95 + ветер ≥ 14 м/с или порывы ≥ 20"), ("hail", "96 99 гроза с градом"),
    ]),
    ("Производные — перекрывают WMO по другим полям", [
        ("windyDay", "0–2 + ветер ≥ 10 м/с или порывы ≥ 15 · день"), ("windyNight", "то же · ночь"),
        ("cloudWindy", "3 + ветер ≥ 10 м/с"), ("blizzard", "снег + ветер ≥ 10 м/с"),
        ("sleet", "дождь/морось при 0…+2°"), ("hot", "0–1 днём и ≥ 30°"), ("frostyClear", "0–1 днём и ≤ −10°"),
    ]),
    ("Фазы луны (ясная ночь, считаются по дате)", [
        ("moon0", "новолуние"), ("moon1", "молодая"), ("moon2", "растущий серп"), ("moon3", "растущая"),
        ("moon4", "полнолуние"), ("moon5", "убывающая"), ("moon6", "последняя четверть"), ("moon7", "старая"),
    ]),
    ("Иконки страниц (B) и деталей", [
        ("feelsWarm", "ощущается ≥ 10°"), ("feelsCold", "ощущается < 10°"), ("humidity", "влажность"),
        ("wind", "ветер"), ("umbrella", "вероятность осадков"), ("uv", "UV-индекс"),
        ("sunrise", "восход"), ("sunset", "закат"),
    ]),
]


# ---- the browser mockup ------------------------------------------------------------

def hexrows(grid):
    return ["".join("%02x%02x%02x" % c if c else "000000" for c in r) for r in grid]


def layout_a(v):
    """Anchor + ticker for the page: the temperature both ways, every line,
    and the icon each line brings in Hybrid."""
    top = {("true" if fc else "false"): hexrows(big_temp(v, fc).px) for fc in (True, False)}
    lines = detail_lines(v)
    return {"top": top, "items": {k: hexrows(a.px) for k, a in lines.items()},
            "icons": {k: item_icon(v, k) or v.icon for k in lines}}


def layout_b(v):
    by_fc = {fc: pages(v, fc) for fc in (True, False)}
    out = []
    for (key, icon, area), (_, _, area0) in zip(by_fc[True], by_fc[False]):
        rows = {"1": hexrows(area.px)}
        if key == "temp" and v.r is not None:
            rows["0"] = hexrows(area0.px)
        out.append({"key": key, "icon": icon, "rows": rows})
    return {"pages": out}


def icon_rows(frames):
    return {"frames": [hexrows(f) for f, _ in frames], "ms": [ms for _, ms in frames]}


def main():
    allicons = {n: icon_rows(icon_frames(n)) for n in all_icons()}
    cases = []
    for sc in CASES:
        v = View(sc["reading"], case_config(sc, items=tuple(ORDER)), sc["now"], timezone.utc)
        cases.append({"id": sc["id"], "desc": sc["desc"], "icon": v.icon, "A": layout_a(v), "B": layout_b(v)})
    data = {"W": W, "H": H, "areaX": AREA_X, "icons": allicons, "cases": cases, "groups": GROUPS}
    tpl = open(os.path.join(HERE, "wtemplate.html"), encoding="utf-8").read()
    out = os.path.join(HERE, "index.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(tpl.replace("/*DATA*/null", json.dumps(data, separators=(",", ":"))))
    print(out, len(cases), "cases")


if __name__ == "__main__":
    main()
