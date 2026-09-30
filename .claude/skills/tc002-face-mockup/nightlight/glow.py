"""Soft glow (ambient corner): the tail of a red-amber lamp standing just
past the bottom-right corner (the user's brief, 2026-09-29), drawn as the
sheet's panel pixel for pixel.

The picture is the sheet's panel (`out/sheet-52x16.json`), each cell taken
to the nearest approved colour by RGB distance: an oval of light from the
corner, near-yellow at its core, its rim broken into scattered dim red
pixels up the right edge and along the bottom. The core keeps the sheet's
255/144 rather than the brief's "no yellow": the mock is what was judged.

The motion is the brief's, on that picture, at 10 frames a second so each
frame moves only a few pixels (at 4 frames a second nine stepped at once and
the breath read as jerky):
  brightness — a sine every 12 s: the glow a step brighter, then a step
               dimmer than the sheet, each pixel at its own moment of the
               sine, the nearest to the lamp first — the change flows out
               from the corner and back; an amber pixel's step up is also a
               step warmer (224/40 → 224/72), the brief's colour breathing;
  radius     — a sine every 24 s, slower, as the brief asks: the rim grows
               by a pixel (the dark dots touching it light 40 red) and draws
               back (its 40 red dots go dark), one pixel at a time;
  free dots  — the scattered red dots left of the glow flare a step and
               settle, each on its own period, never going dark.
A pixel steps within its own family — red stays red, amber stays amber: a
red rim dot stepped to 144/40 popped out orange on the panel.
"""
import math

from nlengine import W, H, Layer, PixelScene

FRAME_MS = 100          # 10 cs: smooth; the brief's 2–4 frames a second moved nine pixels a frame
CYCLE_FRAMES = 240      # 24 s at 1×: two brightness breaths, one radius breath (½× doubles it to 480)

# The approved colours, 1 … f, one ramp from the dimmest red to the corner's
# near-yellow: the full grid (every panel red; green 40 from red 144, 72 and
# 100 from 224, 144 at 255) — the sheet's core is 255/144 and its rim passes
# 176 red, 224/40 and 224/72 on the way, none of which a 9-colour list had.
LEVELS = [(40, 0, 0), (100, 0, 0), (144, 0, 0), (144, 40, 0), (160, 0, 0), (176, 0, 0), (176, 40, 0),
          (192, 0, 0), (192, 40, 0), (224, 40, 0), (224, 72, 0), (224, 100, 0), (255, 72, 0), (255, 100, 0),
          (255, 144, 0)]

# The sheet's panel on our ramp (hex digits), one mock dot per cell: the mock
# draws its panel on its own LED grid (58 × 14 dots at 11.75 px), so it is read
# on that grid — its right 52 columns, its 14 rows at the bottom — and each dot
# taken to the nearest colour of the grid or of the unlit dot, by RGB distance.
# (Reading it as 52 × 16 cells stretched 14 rows over 16 and doubled rows: the
# free dots left of the glow came out as vertical pairs.)
GLOW_Y = 0
GLOW = [
    "....................................................",
    "....................................................",
    "....................................................",
    ".................................................3.1",
    "...............................................2...2",
    "..............................................1..122",
    "...........................................2...21222",
    ".............................................1222223",
    ".................................3.........221223338",
    ".........................................212222366aa",
    ".....................................151121233568aaa",
    "................................3..111123233558aaabd",
    ".............................31...131223335889aaddde",
    ".....................2...3..11121232333356aaabbdeeec",
    "...............2...2..1.1.1122322335568aaaaabdeeeeff",
    ".................1..121222333665668aaaadddefffffffff",
]

LAMP_X, LAMP_Y = 55, 18 # the lamp, just past the corner
JITTER = 6              # quarter pixels of distance either way, fixed per pixel: a ragged front
HALF = 2048             # half a turn of the sine, in 1/4096 turns
BRIGHT_TURNS, RADIUS_TURNS = 2, 1
FIRST, LAST = 40, 960   # the earliest / latest moment a pixel steps, 1/4096 turns after the sine's zero
SPARSE = 4              # a red pixel with this many dark neighbours of eight is a free dot
FLARE_TURNS = [2, 3, 4] # a free dot flares every 12, 8 or 6 s
FLARE = 15              # frames a flare lasts: 1.5 s


def base(x, y):
    d = y - GLOW_Y
    if not 0 <= d < len(GLOW):
        return 0
    ch = GLOW[d][x]
    return 0 if ch == "." else int(ch, 16)


def jitter(x, y):
    h = ((x * 73856093) ^ (y * 19349663) ^ 0x5BD1E995) & 0xFFFFFFFF
    h = (h * 2654435761 & 0xFFFFFFFF) >> 16
    return h * 2 * JITTER // 0xFFFF - JITTER


RED = [lv for lv in range(1, len(LEVELS) + 1) if LEVELS[lv - 1][1] == 0]
AMBER = [lv for lv in range(1, len(LEVELS) + 1) if LEVELS[lv - 1][1] > 0]


def dark_around(x, y):
    return sum(1 for dx in (-1, 0, 1) for dy in (-1, 0, 1)
               if (dx or dy) and 0 <= x + dx < W and 0 <= y + dy < H and not base(x + dx, y + dy))


def sparse(x, y):
    return base(x, y) in RED and dark_around(x, y) >= SPARSE


def _body():
    return [(x, y) for y in range(H) for x in range(W) if base(x, y) and not sparse(x, y)]


def _moments(pixels):
    """Each pixel's moment in a breath, 1/4096 turns: by its distance from
    the lamp plus a fixed jitter, spaced evenly by rank so the same few
    pixels change every frame."""
    key = {p: math.isqrt(16 * ((p[0] - LAMP_X) ** 2 + (p[1] - LAMP_Y) ** 2)) + jitter(*p) for p in pixels}
    ranked = sorted(pixels, key=lambda p: (key[p], p))
    last = max(1, len(ranked) - 1)
    return {p: FIRST + (LAST - FIRST) * i // last for i, p in enumerate(ranked)}


BODY = set(_body())
# The radius breath's pixels: the body's 40 red rim, which goes dark, and the
# dark dots touching a brighter body pixel, which light.
SHRINK = {p for p in BODY if base(*p) == 1 and dark_around(*p)}
GROW = {(x + dx, y + dy) for x, y in BODY if base(x, y) >= 2 for dx in (-1, 0, 1) for dy in (-1, 0, 1)
        if 0 <= x + dx < W and 0 <= y + dy < H and not base(x + dx, y + dy)}
BRIGHT_AT = _moments(sorted(BODY))
RADIUS_AT = _moments(sorted(SHRINK | GROW))


def turn(frame, n, turns):
    """The loop's position in 1/4096 turns of a sine that turns `turns` times."""
    return frame * turns * 4096 // n % 4096


def side(t, at):
    """+1 while the sine is past this pixel's moment above zero, −1 below, else 0."""
    if at < t < HALF - at:
        return 1
    if HALF + at < t < 2 * HALF - at:
        return -1
    return 0


def flare(frame, n, x, y):
    lv = base(x, y)
    h = (jitter(y, x) + JITTER) * 7919 + x * 31 + y * 17     # a fixed per-dot hash
    period = CYCLE_FRAMES // FLARE_TURNS[h % len(FLARE_TURNS)]
    up = (frame * CYCLE_FRAMES // n + h) % period < FLARE
    return RED[min(len(RED) - 1, RED.index(lv) + 1)] if up else lv


def drawn(frame, n, x, y):
    """The level a pixel is drawn at, 0 for black."""
    lv = base(x, y)
    if (x, y) in GROW:
        return 1 if side(turn(frame, n, RADIUS_TURNS), RADIUS_AT[(x, y)]) > 0 else 0
    if not lv:
        return 0
    if (x, y) not in BODY:
        return flare(frame, n, x, y)
    if (x, y) in SHRINK and side(turn(frame, n, RADIUS_TURNS), RADIUS_AT[(x, y)]) < 0:
        return 0
    family = RED if lv in RED else AMBER
    i = family.index(lv) + side(turn(frame, n, BRIGHT_TURNS), BRIGHT_AT[(x, y)])
    return family[max(0, min(len(family) - 1, i))]


def design(lv):
    return (lv * 16 + 8, 0, 0)                              # 15 levels fit a red channel at 16 apart


def tint(r):
    lv = r // 16
    return LEVELS[min(len(LEVELS), lv) - 1] if lv >= 1 else (0, 0, 0)


def scene():
    top = len(LEVELS)
    body = [(x, y, design(top)) for x, y in sorted(BODY | GROW)]
    dots = [(x, y, design(top)) for y in range(H) for x in range(W) if base(x, y) and (x, y) not in BODY]

    def light(frame, n, i, x, y):
        lv = drawn(frame, n, x, y)
        return (lv * 16 + 8) * 1000 // (top * 16 + 8) if lv else 0

    return PixelScene("glow", "Мягкое свечение", [Layer("glow", body, light, key="glowBreath"),
                                                   Layer("dots", dots, light, key="glowTwinkle")],
                      FRAME_MS, CYCLE_FRAMES, tint=tint)
