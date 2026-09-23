#!/usr/bin/env python3
"""TC002 (52x16) Better Weather face — mockups.

Python computes every pixel: icons (icons.py), the big temperature, each
detail line. index.html composes them by rectangle (icon | right area) and
plays page changes as row shifts, so no pixel is invented in the browser.
"""
import json, os, sys
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
    "t": ["#..", "###", "#..", "#..", ".##"], "u": ["#.#", "#.#", "#.#", "#.#", ".##"],
    "v": ["#.#", "#.#", "#.#", "#.#", ".#."], "w": ["#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
    "y": ["#.#", "#.#", ".##", "..#", "##."],
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


def arrow(from_deg):
    to = (from_deg + 180) % 360
    return "⇑⇗⇒⇘⇓⇙⇐⇖"[round(to / 45) % 8]


def f2c(f):
    return (f - 32) * 5 / 9


# ---- scenarios ---------------------------------------------------------------

def S(id, desc, theme, t, fl, hum, wind, wdir, gust, hi, lo, pop, uv, sun, hourly, units="c", wunit="m/s"):
    return dict(id=id, desc=desc, theme=theme, t=t, fl=fl, hum=hum, wind=wind, wdir=wdir, gust=gust,
                hi=hi, lo=lo, pop=pop, uv=uv, sun=sun, hourly=hourly, units=units, wunit=wunit)


def hours(a, b, bump=0, rain=()):
    """11 hourly points easing from a to b with a mid bump; rain = indexes with pop>=50."""
    pts = []
    for i in range(11):
        k = i / 10
        pts.append((a + (b - a) * k + bump * (1 - abs(2 * k - 1)), i in rain))
    return pts


CASES = [
    S("01-clear-day", "ясно днём, жарко, UV высокий", "clearDay", 24, 26, 38, 3, 225, 5, 27, 15, 0, 7, ("set", "19:42"), hours(24, 18, 3)),
    S("02-clear-night", "ясная ночь, штиль", "clearNight", 12, 11, 71, 1, 90, 2, 22, 9, 5, 0, ("rise", "6:48"), hours(12, 9, -1)),
    S("03-partly-day", "переменная облачность днём", "partlyCloudyDay", 8, 5, 64, 6, 300, 9, 11, 3, 20, 3, ("set", "18:57"), hours(8, 5, 2)),
    S("04-partly-night", "переменная облачность ночью", "partlyCloudyNight", 6, 3, 80, 4, 270, 7, 9, 2, 10, 0, ("rise", "7:02"), hours(6, 3)),
    S("05-overcast", "пасмурно, около нуля", "cloudDay", -1, -6, 86, 7, 0, 12, 1, -3, 40, 1, ("set", "17:31"), hours(-1, -3, 1, (8, 9, 10))),
    S("06-overcast-night", "пасмурная ночь", "cloudNight", 2, -1, 90, 3, 200, 5, 4, 0, 30, 0, ("rise", "8:15"), hours(2, 0)),
    S("07-fog", "туман, влажность 100%", "fog", 3, 1, 100, 1, 160, 2, 7, 1, 10, 0, ("set", "17:05"), hours(3, 6, 1)),
    S("08-drizzle", "морось", "drizzle", 9, 7, 93, 4, 250, 7, 11, 7, 60, 1, ("set", "18:20"), hours(9, 8, 1, (0, 1, 2, 3))),
    S("09-rain", "дождь, вероятность 90%", "rain", 14, 13, 95, 8, 210, 14, 16, 11, 90, 1, ("set", "19:10"), hours(14, 12, 0, (0, 1, 2, 3, 4, 5))),
    S("10-snow-feels", "снег −12°, ощущается −19° (цвет по ощущаемой)", "snow", -12, -19, 85, 5, 20, 9, -9, -15, 80, 0, ("set", "16:48"), hours(-12, -15, 1, (0, 1, 2, 3, 4))),
    S("11-freezing", "ледяной дождь / гололёд", "frost", -3, -8, 92, 6, 45, 10, -1, -5, 70, 0, ("set", "17:12"), hours(-3, -5, 0, (2, 3, 4, 5))),
    S("12-thunder", "гроза, душно", "thunder", 22, 25, 78, 6, 180, 15, 28, 18, 70, 5, ("set", "20:14"), hours(22, 19, 4, (3, 4, 5, 6))),
    S("13-storm", "шторм: ветер 17 м/с, порывы 25", "storm", 19, 16, 90, 17, 270, 25, 21, 15, 95, 2, ("set", "20:02"), hours(19, 16, 0, tuple(range(11)))),
    S("14-extreme-cold", "экстрим −35°, ощущается −44°", "clearDay", -35, -44, 60, 4, 0, 6, -30, -38, 0, 1, ("set", "15:40"), hours(-35, -38, 3)),
    S("15-fahrenheit", "°F и mph: 104°f, трёхзначная ширина", "clearDay", 104, 111, 20, 9, 120, 15, 106, 82, 0, 11, ("set", "20:30"), hours(104, 90, 4), "f", "mph"),
    S("17-windy", "ясно, но ветер 12 м/с — иконка «ветрено» вместо солнца", "windyDay", 11, 6, 45, 12, 290, 19, 13, 6, 0, 3, ("set", "18:40"), hours(11, 8, 1)),
    S("18-heat", "жара 36° — иконка «жара»", "hot", 36, 39, 25, 2, 150, 4, 38, 24, 0, 10, ("set", "21:05"), hours(36, 28, 2)),
    S("19-showers", "ливень с прояснениями (WMO 80–81)", "showersDay", 17, 16, 82, 5, 230, 11, 20, 13, 60, 4, ("set", "19:55"), hours(17, 15, 1, (1, 2, 6, 7))),
    S("20-moon", "ясная ночь — луна в текущей фазе (растущая)", "moon2", 9, 7, 76, 2, 60, 3, 16, 6, 0, 0, ("rise", "6:55"), hours(9, 6)),
    S("16-no-data", "нет данных (сеть/место не задано)", None, None, None, None, None, None, None, None, None, None, None, None, None),
]


# Gallery groups: (title, [(icon, trigger)]) — the trigger is what selects it.
GROUPS = [
    ("По коду WMO (Open-Meteo weather_code)", [
        ("clearDay", "0 · день"), ("moon4", "0 · ночь → луна в текущей фазе"),
        ("mainlyClearDay", "1 · день"), ("mainlyClearNight", "1 · ночь"),
        ("partlyCloudyDay", "2 · день"), ("partlyCloudyNight", "2 · ночь"),
        ("cloudDay", "3 · день"), ("cloudNight", "3 · ночь"),
        ("fog", "45 туман"), ("rimeFog", "48 изморозевый туман"),
        ("drizzle", "51 53 55 морось"), ("freezingRain", "56 57 66 67 ледяной дождь"),
        ("rain", "61 63 дождь"), ("heavyRain", "65 82 сильный дождь"),
        ("showersDay", "80 81 ливень · день"), ("showersNight", "80 81 ливень · ночь"),
        ("snow", "71 73 75 77 снег"), ("snowShowersDay", "85 86 снежный заряд · день"),
        ("snowShowersNight", "85 86 снежный заряд · ночь"),
        ("thunder", "95 гроза"), ("storm", "95 + ливень или ветер ≥ 14 м/с"), ("hail", "96 99 гроза с градом"),
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


def celsius(sc, v):
    return f2c(v) if sc["units"] == "f" else v


def deg(v):
    return "%d°" % round(v)


# ---- pieces -------------------------------------------------------------------

def big_temp(sc, feels_colour, h=9):
    a = Area(AREA_W, h)
    if sc["t"] is None:
        a.text("--°", 0, 0, DIM, B)
        return a
    ink = temp_colour(celsius(sc, sc["fl"] if feels_colour else sc["t"]))
    x = a.text(deg(sc["t"]), 0, 0, ink, B)
    unit = sc["units"]
    if x + 1 + width(unit) <= AREA_W:
        a.text(unit, x + 1, 4, LABEL)
    return a


def line(parts):
    a = Area(AREA_W, 5)
    a.runs(0, 0, parts)
    return a


def hilo_parts(sc):
    """Today's high and low; the degree signs go first when both do not fit."""
    for d in (deg, lambda v: "%d" % round(v)):
        parts = [("↑", LABEL, G, 1), (d(sc["hi"]), temp_colour(celsius(sc, sc["hi"])), G, 3),
                 ("↓", LABEL, G, 1), (d(sc["lo"]), temp_colour(celsius(sc, sc["lo"])), G)]
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


def detail_lines(sc):
    """Every detail the ticker can show, keyed by the tile setting that owns it."""
    if sc["t"] is None:
        return {"nodata": line([("no data", DIM, G)])}
    wtext = "%d" % sc["wind"]
    windparts = [(arrow(sc["wdir"]), wind_colour(sc["wind"] if sc["wunit"] == "m/s" else sc["wind"] / 2.237), G, 2)]
    if sc["gust"] and sc["gust"] - sc["wind"] >= 5:
        windparts += [(wtext, wind_colour(sc["wind"]), G), ("g", LABEL, G, 1), ("%d" % sc["gust"], wind_colour(sc["gust"]), G)]
    else:
        windparts += [(wtext + " " + sc["wunit"], wind_colour(sc["wind"] if sc["wunit"] == "m/s" else sc["wind"] / 2.237), G)]
    ev, at = sc["sun"]
    out = {
        "feels": line([("fl", LABEL, G), (deg(sc["fl"]), temp_colour(celsius(sc, sc["fl"])), G)]),
        "humidity": line([("h", LABEL, G), ("%d%%" % sc["hum"], HUM, G)]),
        "wind": line(windparts),
        "hilo": line(hilo_parts(sc)),
        "rain": line([("rain", LABEL, G), ("%d%%" % sc["pop"], RAINC if sc["pop"] >= 30 else LABEL, G)]),
        "uv": line([("uv", LABEL, G), ("%d" % sc["uv"], uv_colour(sc["uv"]), G)]),
        "sun": line([(ev, LABEL, G), (at, SUNC, G)]),
        "hourly": hourly_chart(sc),
    }
    return out


def hourly_chart(sc):
    """11 bars (2 px + 1 gap) of the next hours, height by temperature within
    the day's range, colour by temperature; a blue cap where rain is likely."""
    a = Area(AREA_W, 5)
    temps = [t for t, _ in sc["hourly"]]
    lo, hi = min(temps), max(temps)
    for i, (t, wet) in enumerate(sc["hourly"]):
        hgt = 1 + round((t - lo) / (hi - lo) * 3) if hi > lo else 2
        x = i * 3
        c = temp_colour(celsius(sc, t))
        for y in range(5 - hgt, 5):
            a.put(x, y, c)
            a.put(x + 1, y, c)
        if wet:
            a.put(x, 4 - hgt, RAIN_CAP)
            a.put(x + 1, 4 - hgt, RAIN_CAP)
    return a


def big_page(value_text, value_colour, label_parts, font=B):
    a = Area()
    a.text(value_text, 0, 0, value_colour, font)
    a.runs(0, 11, label_parts)
    return a


def item_icon(sc, key):
    """Hybrid: the icon a ticker line brings with it; None keeps the weather's."""
    if sc["t"] is None:
        return None
    return {
        "feels": "feelsWarm" if celsius(sc, sc["fl"]) >= 10 else "feelsCold",
        "humidity": "humidity", "wind": "wind", "rain": "umbrella", "uv": "uv",
        "sun": "sunrise" if sc["sun"][0] == "rise" else "sunset",
    }.get(key)


def layout_a(sc):
    """Anchor + ticker: the temperature never moves, one detail line rotates.
    `icons` is what Hybrid shows beside each line."""
    top = {fc: big_temp(sc, fc).rows() for fc in (True, False)}
    lines = detail_lines(sc)
    return {"top": top, "items": {k: v.rows() for k, v in lines.items()},
            "icons": {k: item_icon(sc, k) or sc["theme"] or "nodata" for k in lines}}


def layout_b(sc):
    """Pages: each page is its own icon + one big figure + a label."""
    if sc["t"] is None:
        return {"pages": [{"key": "temp", "icon": "nodata", "rows": {"1": big_page("--°", DIM, [("no data", DIM, G)]).rows()}}]}
    pages = []
    temp = {}
    for fc in (True, False):
        a = big_temp(sc, fc)
        full = Area()
        for y in range(9):
            full.px[y] = a.px[y][:]
        full.runs(0, 11, hilo_parts(sc))
        temp["1" if fc else "0"] = full.rows()
    pages.append({"key": "temp", "icon": sc["theme"], "rows": temp})
    flc = celsius(sc, sc["fl"])
    fp = big_page(deg(sc["fl"]), temp_colour(flc), [("feels", LABEL, G)])
    ux = width(deg(sc["fl"]), B) + 1
    if ux + width(sc["units"]) <= AREA_W:
        fp.text(sc["units"], ux, 4, LABEL)   # a temperature always names its scale
    pages.append({"key": "feels", "icon": "feelsWarm" if flc >= 10 else "feelsCold", "rows": {"1": fp.rows()}})
    hp = big_page("%d%%" % sc["hum"], HUM, [("humidity", LABEL, G)])
    pages.append({"key": "humidity", "icon": "humidity", "rows": {"1": hp.rows()}})
    wp = Area()
    wc = wind_colour(sc["wind"] if sc["wunit"] == "m/s" else sc["wind"] / 2.237)
    x = wp.text("%d" % sc["wind"], 0, 0, wc, B)
    wp.text(sc["wunit"], x + 2, 4, LABEL)
    wp.runs(0, 11, [(arrow(sc["wdir"]), wc, G)] + ([("g", LABEL, G, 1), ("%d" % sc["gust"], wind_colour(sc["gust"]), G)] if sc["gust"] - sc["wind"] >= 5 else []))
    pages.append({"key": "wind", "icon": "wind", "rows": {"1": wp.rows()}})
    return {"pages": pages}


def nodata_icon():
    f = icons.blank()
    icons.cloud(f, 0, 4, "nt")
    return [(f, 1000)]


def icon_rows(frames):
    return {"frames": [["".join("%02x%02x%02x" % c if c else "000000" for c in r) for r in f] for f, _ in frames],
            "ms": [ms for _, ms in frames]}


def main():
    allicons = {n: icon_rows(fn()) for n, fn in
                {**icons.THEMES, **icons.DERIVED, **icons.MOON, **icons.PAGE_ICONS}.items()}
    allicons["nodata"] = icon_rows(nodata_icon())
    cases = []
    for sc in CASES:
        cases.append({"id": sc["id"], "desc": sc["desc"], "icon": sc["theme"] or "nodata",
                      "A": layout_a(sc), "B": layout_b(sc)})
    data = {"W": W, "H": H, "areaX": AREA_X, "icons": allicons, "cases": cases, "groups": GROUPS}
    tpl = open(os.path.join(HERE, "wtemplate.html"), encoding="utf-8").read()
    out = os.path.join(HERE, "index.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(tpl.replace("/*DATA*/null", json.dumps(data, separators=(",", ":"))))
    print(out, len(cases), "cases")


if __name__ == "__main__":
    main()
