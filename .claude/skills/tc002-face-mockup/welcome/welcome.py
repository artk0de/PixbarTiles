#!/usr/bin/env python3
"""Welcome screen mockups: what the clock shows for 10 s when PixbarTiles
connects, before the tile pages arrive. TC002 (52x16) and AWTRIX (32x8).

The motion is the app's own logo: the P flows through the three colours the
icon gave it (approved flow F1: blended, one band per 600 ms, falling); the
sparkle breathes; the rest holds.

Python is the only source of pixels: every candidate becomes a timeline of
(frame, ms) per panel; index.html embeds the timelines and only plays them.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))     # the skill's gen.py (font, PNG writer)
from gen import G  # the kit's 3x5 font
import gen

OUT = os.environ.get("OUT") or os.path.join(os.getcwd(), "welcome-mockup-out")
VERSION = os.environ.get("VERSION", "v0.1.0")
SHOW_MS = 10_000          # the welcome is forced on, and taken down after 10 s
FRAME_MS = 80             # 125 frames for the whole show: well inside 480


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# The app icon's colours.
BLUE, WHITE, PURPLE, CYAN = hexrgb("#4fb8f5"), hexrgb("#eef0f4"), hexrgb("#b65cf5"), hexrgb("#63d1ff")
BANDS = [BLUE, WHITE, PURPLE]
GREY = (0x88, 0x88, 0x88)

# The wordmark as shipped in the app (PanelGlyph "PIXBAR", .tiny): 23 x 5.
WORD = ["###.###.#.#.##...#..##.",
        "#.#..#..#.#.#.#.#.#.#.#",
        "###..#...#..##..###.##.",
        "#....#..#.#.#.#.#.#.#.#",
        "#...###.#.#.##..#.#.#.#"]
# The app icon's P, 7 x 9.
P_APP = ["######.", "#######", "###..##", "###..##", "#######", "######.", "###....", "###....", "###...."]

# PIXBAR bold, 7 rows: the wordmark's letterforms with 2-px strokes. 34 x 7.
BOLD = {
    "P": ["####.", "##.##", "##.##", "####.", "##...", "##...", "##..."],
    "I": ["####", ".##.", ".##.", ".##.", ".##.", ".##.", "####"],
    "X": ["##.##", "##.##", "##.##", ".###.", "##.##", "##.##", "##.##"],
    "B": ["####.", "##.##", "##.##", "####.", "##.##", "##.##", "####."],
    "A": [".###.", "##.##", "##.##", "#####", "##.##", "##.##", "##.##"],
    "R": ["####.", "##.##", "##.##", "####.", "##.##", "##.##", "##.##"],
}


def brand_bold():
    """PIXBAR bold derived mechanically from the brand wordmark: each 3-col
    letter's outer columns doubled (2-px strokes), the middle column kept
    single; rows 1 and 3 doubled (5 -> 7 rows). 35 x 7."""
    out = {}
    for i, ch in enumerate("PIXBAR"):
        rows = [r[i * 4:i * 4 + 3] for r in WORD]
        wide = [r[0] * 2 + r[1] + r[2] * 2 for r in rows]
        out[ch] = [wide[j] for j in (0, 1, 1, 2, 3, 3, 4)]
    return out


BRAND_BOLD = brand_bold()

# Sparkles. The icon's is the outline of a plus with arms 3 wide, the four arm
# tips left open; at one LED per icon half-cell that is 7x7.
SPARK7 = ["..#.#..",
          "..#.#..",
          "##...##",
          ".......",
          "##...##",
          "..#.#..",
          "..#.#.."]
# The same outline with arms one step shorter: 5x5, still open at the tips.
SPARK5_OPEN = [".#.#.",
               "##.##",
               ".....",
               "##.##",
               ".#.#."]
# The breath's smaller phases (TC002).
SPARK3 = [".#.", "#.#", ".#."]
SPARK1 = ["#"]
# AWTRIX keeps a plain plus that only dims a little.
PLUS3 = [".#.", "###", ".#."]


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def dim(c, k):
    return tuple(round(v * k) for v in c)


def cyclic(pos):
    """A colour on the closed loop blue -> white -> purple -> blue; pos in
    band units (1.0 = one band)."""
    pos %= 3
    i = int(pos)
    return mix(BANDS[i], BANDS[(i + 1) % 3], pos - i)


def flow_f1(col, row, rows, t):
    """F1: the icon's three bands roll down through the P, blended, one band
    every 600 ms."""
    return cyclic(row * 3 / rows - t / 600)


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[None] * w for _ in range(h)]

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def bitmap(self, rows, x, y, colour):
        """colour: an RGB, or a function (col, row) -> RGB|None."""
        for dy, row in enumerate(rows):
            for dx, ch in enumerate(row):
                if ch == "#":
                    c = colour(dx, dy) if callable(colour) else colour
                    if c:
                        self.put(x + dx, y + dy, c)

    def text(self, s, x, y, c, font=G):
        for ch in s:
            self.bitmap(font[ch], x, y, c)
            x += len(font[ch][0]) + 1


def text_width(s, font=G):
    return sum(len(font[ch][0]) + 1 for ch in s) - 1


def spark_phase(t_ms, period=2000):
    """TC002: the sparkle breathes — full most of the time, a quick
    shrink-and-back."""
    k = t_ms % period
    for until, phase in ((1500, 3), (1600, 2), (1700, 1), (1850, 0), (1925, 1)):
        if k < until:
            return phase
    return 2


def plus_level(t_ms, period=2000):
    """AWTRIX: the plus keeps its shape and only dips in brightness."""
    k = t_ms % period
    for until, level in ((1500, 1.0), (1600, 0.75), (1750, 0.5), (1850, 0.75)):
        if k < until:
            return level
    return 1.0


def spark_colour(t_ms, period=2000):
    """TC002: the sparkle keeps its shape and flows white -> cyan -> white."""
    import math
    return mix(WHITE, CYAN, (1 - math.cos(2 * math.pi * t_ms / period)) / 2)


def draw_spark(cv, full, centre, colour, phase=3):
    """The sparkle blinks (spark_phase: full, shrink, out, back) while its
    colour flows (spark_colour)."""
    rows = {3: full, 2: SPARK3, 1: SPARK1, 0: []}[phase]
    if rows:
        n = len(rows)
        cv.bitmap(rows, centre[0] - n // 2, centre[1] - n // 2, colour)


# ---------------------------------------------------------------- variants
# Where the TC002 sparkle sits, relative to the P's top-left, and which
# outline it has. On the icon its centre is at (9.75, 0.75) P-cells: one
# column past the P, level with the P's top row.
SPARKS = [
    ("S3", "5×5 открытая искорка, заходит на срезанный угол P — на 1 px выше исходной S3", SPARK5_OPEN, (9, -1)),
]

# Twinkles: single-LED stars that come in white, turn light blue and go out,
# each on its own period and offset so they never blink together.
LIGHT_BLUE = hexrgb("#a8e2ff")
# (x, y, period ms, offset ms), panel coordinates. The sparkle's box is
# x 9..13, y 1..5; the P's is x 3..9, y 4..12; PIXBAR starts at x 15.
TW_SPARK = [(8, 1, 1900, 0), (13, 7, 2300, 700), (11, 0, 2100, 1400), (7, 3, 2600, 1100)]
TW_P = [(1, 3, 2200, 300), (0, 8, 2500, 1600), (1, 13, 1800, 900), (5, 14, 2400, 200),
        (11, 11, 2000, 1200), (12, 14, 2700, 500)]
# The empty patch left of the version (x 15..29, rows 9..15).
TW_VERSION = [(16, 11, 2100, 400), (19, 14, 2500, 1300), (22, 10, 1900, 800), (25, 13, 2300, 0),
              (28, 11, 2600, 1700)]


def tw_letter_i(font):
    """Two stars over the I (row 0) and two under it (row 8), just off its
    corners, wherever the font puts it."""
    x0 = 15 + len(font["P"][0]) + 1
    x1 = x0 + len(font["I"][0]) - 1
    return [(x0 - 1, 0, 2200, 600), (x1 + 1, 0, 1800, 1500), (x0 - 2, 9, 2400, 1000), (x1, 9, 2000, 100),
            (x1 + 1, 4, 2300, 1200)]   # between I and X, in the pocket beside X's waist


def t1_plus(font):
    return TW_SPARK + TW_VERSION + tw_letter_i(font)


# The brand bold with a 2-px I stem: an even width centres it.
BRAND_I4 = dict(BRAND_BOLD, I=["####", ".##.", ".##.", ".##.", ".##.", ".##.", "####"])
BRAND_I6 = dict(BRAND_BOLD, I=["######", "..##..", "..##..", "..##..", "..##..", "..##..", "######"])

# The approved base: T1+brand · I4 · F1.
FONT = BRAND_I4
# Under the logo (the P ends on row 12): rows 13..15, x 1..13.
TW_UNDER = [(1, 14, 2200, 900), (4, 13, 2600, 300), (7, 15, 1900, 1500), (10, 13, 2400, 700),
            (13, 15, 2100, 1100)]
# Left of the P (it starts at x 2): column 0, a free column between.
TW_LEFT = [(2, 2, 2300, 400), (0, 10, 2000, 1300)]   # the upper one in the top-left area, over the P
STARS = t1_plus(BRAND_I4) + TW_UNDER + TW_LEFT

# The version's own loop, at 85 % so PIXBAR stays first. The first try
# (cyan, light blue, lavender) read as the P's gradient again; each candidate
# swaps one colour for a neighbour that still sits in the palette.
LAVENDER = hexrgb("#c3a6ff")
MINT, PINK, INDIGO = hexrgb("#6ff0d0"), hexrgb("#ff8fd8"), hexrgb("#7a7cff")
VERSION_LOOPS = [
    ("Vb", "версия: лавандовый → розовый #ff8fd8 → светло-голубой", [LAVENDER, PINK, LIGHT_BLUE]),
]
VERSION_LOOP = VERSION_LOOPS[0][2]


def word_colour(t, period=2400):
    """PIXBAR pulses: white between 100 % and 60 %, quantised to 2.5 % steps
    so the GIF palette stays small."""
    import math
    level = 0.8 + 0.2 * math.cos(2 * math.pi * t / period)
    return dim(WHITE, round(level * 40) / 40)


def version_colour(x, y, t):
    """A diagonal wave across the version, one band per 800 ms, quantised to
    eighths of a band so the GIF palette stays small."""
    pos = round(((x + y) / 6 - t / 800) * 8) / 8 % 3
    i = int(pos)
    return dim(mix(VERSION_LOOP[i], VERSION_LOOP[(i + 1) % 3], pos - i), 0.85)

# A star's colour pair: it comes in as the first, flows to the second, goes
# out. The P's own gradient colours, plus the light blue.
STAR_PAIRS = [(WHITE, LIGHT_BLUE), (BLUE, PURPLE), (PURPLE, WHITE), (LIGHT_BLUE, BLUE),
              (WHITE, PURPLE), (BLUE, WHITE)]


def twinkle(t_ms, period, offset, pair=(WHITE, LIGHT_BLUE)):
    """Off, fade in to the first colour, flow to the second, fade out, off."""
    a, b = pair
    k = ((t_ms + offset) % period) / period
    q = lambda v: round(v * 4) / 4     # 5 levels a phase keeps the GIF palette small
    if k < 0.2:
        return dim(a, q(k / 0.2))
    if k < 0.5:
        return mix(a, b, q((k - 0.2) / 0.3))
    if k < 0.75:
        return dim(b, q((0.75 - k) / 0.25))
    return None


def draw_twinkles(cv, stars, t_ms):
    for n, (x, y, period, offset) in enumerate(stars):
        c = twinkle(t_ms, period, offset, STAR_PAIRS[n % len(STAR_PAIRS)])
        if c and max(c) > 24 and cv.px[y][x] is None:   # never over the logo itself
            cv.put(x, y, c)


# ---------------------------------------------------------------- TC002 52x16
# P 7x9 at the left, PIXBAR bold 34x7 after the sparkle, the version (3x5)
# under PIXBAR. The group is centred on its widest extent.
def tc002_layout(full, rel):
    # Pinned as approved with S3: P at x 3, PIXBAR and the version at x 15.
    return (2, 4), (15, 1), (15, 10)   # the P moved 1 px left; the sparkle stays put


def tc002(t, full, rel, stars, font=BOLD):
    cv = Canvas(52, 16)
    (px, py), word, ver = tc002_layout(full, rel)
    cv.bitmap(P_APP, px, py, lambda c, r: flow_f1(c, r, 9, t))
    cv.text("PIXBAR", *word, word_colour(t), font=font)
    # the version's right edge on PIXBAR's right edge
    right = word[0] + text_width("PIXBAR", font)
    x, y = right - text_width(VERSION), ver[1]
    for ch in VERSION:
        cv.bitmap(G[ch], x, y, lambda dx, dy, x=x: version_colour(x + dx, y + dy, t))
        x += len(G[ch][0]) + 1
    # on top: the sparkle may cover the P
    draw_spark(cv, full, (px + rel[0], py + rel[1]), spark_colour(t), spark_phase(t))
    draw_twinkles(cv, stars, t)
    return cv


# ---------------------------------------------------------------- AWTRIX 32x8
# PIXBAR 23x5 whose own P carries the flow, a plain 3x3 plus off its top
# right that folds like the TC002 sparkle (plus, dot, out, dot) and flows
# white -> cyan with it; the version takes the last 3 s by a push up.
A_WORD = (2, 2)
A_PLUS = (26, 0)
A_VERSION_AT = 7_000
PLUS_FOLD = {3: PLUS3, 2: SPARK1, 1: SPARK1, 0: []}


def awtrix(t, dy=0, version=False):
    cv = Canvas(32, 8)
    wx, wy = A_WORD[0], A_WORD[1] + dy
    cv.bitmap(WORD, wx, wy, lambda dx, r: flow_f1(dx, r, 5, t) if dx < 3 else word_colour(t))
    rows = PLUS_FOLD[spark_phase(t)]
    if rows:
        o = (3 - len(rows)) // 2
        cv.bitmap(rows, A_PLUS[0] + o, A_PLUS[1] + o + dy, spark_colour(t))
    if version:
        x, y = (32 - text_width(VERSION)) // 2, 2 + dy + 8
        for ch in VERSION:   # the same diagonal wave as the TC002 version
            cv.bitmap(G[ch], x, y, lambda cx, cy, x=x: version_colour(x + cx, y + cy, t))
            x += len(G[ch][0]) + 1
    return cv


def timeline(panel, full=None, rel=None, stars=(), font=None):
    tl = []
    for n in range(SHOW_MS // FRAME_MS + 1):
        t = n * FRAME_MS
        if panel == "tc":
            cv = tc002(t, full, rel, stars, font or BOLD)
        elif t < A_VERSION_AT:
            cv = awtrix(t)
        else:
            dy = -min(8, ((t - A_VERSION_AT) // FRAME_MS + 1) * 2)   # 8 rows in 4 frames
            cv = awtrix(t, dy=dy, version=True)
        tl.append((cv, FRAME_MS))
    out = []
    for cv, ms in tl:   # identical neighbours become one frame with the summed delay
        if out and out[-1][0].px == cv.px:
            out[-1] = (out[-1][0], out[-1][1] + ms)
        else:
            out.append((cv, ms))
    return out


def encode(cv, palette):
    out = []
    for row in cv.px:
        line = ""
        for c in row:
            c = c or (0, 0, 0)
            if c not in palette:
                palette[c] = len(palette)
            line += chr(48 + palette[c])
        out.append(line)
    return out


def png(cv, path):
    gen.W, gen.H = cv.w, cv.h
    gen.png(cv, path)


def main():
    os.makedirs(OUT, exist_ok=True)
    palette, cases = {}, []
    global VERSION_LOOP
    _, _, full, rel = SPARKS[0]
    for cid, desc, loop in VERSION_LOOPS:
        VERSION_LOOP = loop
        tl = timeline("tc", full, rel, STARS, FONT)
        aw = timeline("aw")
        for tag, i in (("a", 0), ("b", len(tl) // 4)):
            png(tl[i][0], os.path.join(OUT, f"{cid}-tc-{tag}.png"))
        png(aw[-1][0], os.path.join(OUT, f"{cid}-aw-end.png"))
        for name, t in (("tc", tl), ("aw", aw)):
            n = len({c for cv, _ in t for row in cv.px for c in row if c})
            assert n <= 256, f"{cid} {name}: {n} colours, one GIF palette holds 256"
        panels = [{"name": name, "W": t[0][0].w, "H": t[0][0].h,
                   "frames": [{"px": encode(cv, palette), "ms": ms} for cv, ms in t]}
                  for name, t in (("TC002 · 52×16", tl), ("AWTRIX · 32×8", aw))]
        cases.append({"id": cid, "desc": "T1+brand · I4 · F1 · PIXBAR пульсирует · " + desc, "panels": panels})
        print(cid, len(tl), "tc frames,", len(aw), "aw frames")
    pal = ["#%02x%02x%02x" % c for c, _ in sorted(palette.items(), key=lambda kv: kv[1])]
    data = json.dumps({"palette": pal, "version": VERSION, "showMs": SHOW_MS, "cases": cases},
                      ensure_ascii=False, separators=(",", ":"))
    tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "wtemplate.html")).read()
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(tpl.replace("/*DATA*/null", data))
    print("palette", len(palette))


if __name__ == "__main__":
    main()
