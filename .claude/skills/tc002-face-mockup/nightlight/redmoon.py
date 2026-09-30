"""Red Moon: concept 3 of the sheet, redrawn as pixel art on the 52×16 grid —
a crescent leaning to the right, a sky of dim stars and the sheet's
own cloud bank rising from below the screen's edge. The crescent is amber
at its inner limb cooling to dark red at its back; the moonlit cloud rims
and the bright stars are amber.

Every mask is a literal on whole pixels; the crescent's comes
from `make_moon.py`, the clouds' from the sheet's cells (`make_clouds.py`).
Every colour lands on one of the reds the panel tells apart (`PANEL_REDS`),
so nothing may fade smoothly. The crescent stands still, shaded from its
inner limb to its back, with no halo. The bank is a fixed picture drifting
right by whole pixels, one panel width a loop, through a pool of moonlight
fixed under the crescent and drawn in the crescent's own colours. Where the bank passes over
the crescent it covers it. The stars twinkle between levels behind the
clouds.
"""
import math

from nlengine import W, Layer, PixelScene, mask, panel_amber, panel_red, swing

FRAME_MS = 150          # 15 cs
CYCLE_FRAMES = 208      # 31.2 s at 1×: 4 frames a pixel of drift, so every step keeps time

# The crescent: a disc of radius 5 about (9, 6) minus a disc of radius 4.5
# pushed 3.25 px along the axis, the axis turned 25° up-right; supersampled
# and quantised by `make_moon.py`. B the bright inner limb, M the body, T the
# thin edges and horn tips, g the faint rim.
MOON_X, MOON_Y = 3, 1
MOON = [
    "...gMT.....",
    "..TMB......",
    ".gMBT......",
    ".MMBT......",
    ".MMBT......",
    ".MMBM......",
    ".MMMBT.....",
    ".gMMMBTg...",
    "..TMMMBBBT.",
    "...gMMMMg..",
]
# The crescent graded by a pixel's steps from the inner limb: amber at the
# limb cooling to dark red at the back — panel 255/100, 255/72, 192/40, then
# red 160; thin edges 144, the faint rim 100. Picked on the TC002 2026-09-29
# over the same grades in reds only (255 / 224 / 192 / 160), which read flat;
# an amber rim on the back alone read as an orange outline.
MOON_INK = {"0": (185, 100, 0), "1": (185, 72, 0), "2": (120, 40, 0), "3": (64, 0, 0),
            "T": (36, 0, 0), "g": (20, 0, 0)}

# (x, y, peak red, goes out): spread over the whole sky down to the cloud
# crests, clear of the crescent's corner (x 3…13, y 0…11); the bank drifts
# over the low ones. Five stand out at 90…110; four faint ones fade out.
STARS = [
    (1, 2, 46, False), (0, 6, 90, False), (2, 9, 40, True),
    (16, 1, 60, False), (21, 4, 46, True), (16, 9, 90, False), (20, 13, 42, False),
    (24, 11, 40, True), (27, 2, 110, False), (30, 7, 44, False), (34, 12, 40, True),
    (37, 4, 62, False), (40, 9, 96, False), (44, 0, 50, False), (45, 6, 40, False),
    (48, 3, 104, False), (50, 11, 44, False), (43, 13, 38, False),
]
STAR_CYCLES = [3, 4, 5, 4, 3, 5]   # 10, 7.5 and 6 s at 1×
STAR_LOW = -350                     # the sine dips below zero: dark for a while

# Moonlight on the clouds, in the crescent's own colours: a cloud pixel lit
# by the moon walks down the crescent's gradient — limb to back to edges,
# 255/100, 255/72, 192/40, 160, 144, 100 (`moon_ramp`) — one step for every
# ring it lies under the bank's edge and one for every BAND of distance from
# the moon, and keeps its own red once the walk gets darker than that. An
# amber scale of its own read as a second light (the user, 2026-09-29: "цвет
# кромки не совпадает с цветами самого месяца").
#
# The light is fixed on the screen under the crescent and the bank drifts
# through it. Distance is measured from the limb's foot (MOON_CX, GLOW_Y):
# `isqrt((dx * STEP_X) ** 2 + (dy * STEP_Y) ** 2)`, a column counting more to
# the right (the light is gone 4-5 columns past the crescent's right edge)
# than to the left (it reaches the bottom-left corner), a row counting least
# (the pool hangs down under the moon) — so the gradient bends round the moon
# instead of standing in vertical strips, and the light fades with distance
# in every direction. The number of lit rings falls with it: under the moon
# the edge glows four or five rings deep, at the pool's rim only the edge
# itself, dimly (the user picked this over equal three-ring glows, which
# read as an outline).
#
# Ring 0 is the edge — a cloud pixel with sky above, beside or diagonally
# above; ring k+1 has a ring-k pixel there. Edges from each column's top
# left red holes under ragged crests (frame by frame, 2026-09-29).
MOON_CX, GLOW_Y = 7, 10
RIGHT_FROM = 8          # the right-hand fall starts a column later: the pool's amber lines up with the crescent's (the user, 2026-09-29)
STEP_LEFT, STEP_RIGHT, STEP_Y = 4, 6, 3
FIRST, BAND = 1, 14            # the edge right under the limb takes ramp step 1, 255/72
LIT = 200                       # design reds from here up name a ramp step, 10 apart
NEAR = ((-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0))   # above, diagonally above, beside
# Out of the moonlight the bank darkens: from each distance (as above) a
# cloud's own red is held to a design red at most — (from distance, body,
# edge), farthest first: panel 144 from past the pool (about x 20), 100 from
# about x 25, and from about x 33 the body sinks to the floor, 40, while its
# edge keeps 100, so the far bank reads as a dark silhouette; only the stars
# stay bright out there (the user, 2026-09-29: "яркими должны быть только
# звезды").
SHADE = [(150, 8, 20), (100, 20, 20), (70, 36, 36)]

# The sheet's bank cell for cell (`make_clouds.py`: its rows 8…12 on our rows
# 11…15, its columns resampled to ours): the mound in the corner with its
# crest running down the slope, the low band with its lit bumps, the dip,
# the mound's shoulder across the wrap. Each ink is a design red, 4 per step
# ('2' = 8 … 'G' = 64); on the panel they fall into a few levels.
CLOUD_INKS = "..23456789ABCDEFG"
CLOUD_INK = {ch: (4 * i, 0, 0) for i, ch in enumerate(CLOUD_INKS) if ch != "."}
FRONT_Y = 10
FRONT = [
    "A75.................................................",
    "B965556666543332222................................9",
    "9A8765555544333332222.............................68",
    "79AA86555544444554322222.........................456",
    "457998655554456765433333223443454222..........223445",
    "23468876555556897655444333466556533222.....222333334",
]


def graded(rows):
    """The mask with every limb and body pixel (B, M) replaced by its steps
    from the inner limb, 0…3 (3 and beyond are the back); T and g stay."""
    cells = {(x, y) for y, row in enumerate(rows) for x, ch in enumerate(row) if ch != "."}
    steps = {(x, y): 0 for y, row in enumerate(rows) for x, ch in enumerate(row) if ch == "B"}
    frontier = sorted(steps)
    while frontier:
        nxt = []
        for x, y in frontier:
            for q in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if q in cells and q not in steps:
                    steps[q] = steps[(x, y)] + 1
                    nxt.append(q)
        frontier = nxt
    return ["".join(str(min(3, steps[(x, y)])) if ch in "BM" else ch for x, ch in enumerate(row))
            for y, row in enumerate(rows)]


def scene():
    moon = mask(graded(MOON), MOON_INK, MOON_X, MOON_Y)
    stars = [(x, y, (r, star_green(r), 0)) for x, y, r, _ in STARS]
    clouds = mask(FRONT, CLOUD_INK, 0, FRONT_Y)
    ramp = moon_ramp()
    filled = {(x, y) for x, y, _ in clouds}
    ring = {}                                               # rings under the bank's edge (the bank wraps)
    for x, y, _ in clouds:
        if any(((x + dx) % W, y + dy) not in filled for dx, dy in NEAR):
            ring[(x, y)] = 0
    for k in range(1, len(ramp)):
        for x, y, _ in clouds:
            if (x, y) not in ring and any(ring.get(((x + dx) % W, y + dy)) == k - 1 for dx, dy in NEAR):
                ring[(x, y)] = k
    own = [(panel_red(c[0]), 0, 0) for _, _, c in clouds]

    def brighter(step, i):
        """Whether ramp step `step` lights the i-th cloud pixel rather than
        leaving its own red: amber always does, a red only above its own."""
        colour = ramp[step]
        return colour[1] > 0 or colour[0] > own[i][0]

    def twinkle(frame, n, i, x, y):
        cycles = STAR_CYCLES[i % len(STAR_CYCLES)]
        low = STAR_LOW if STARS[i][3] else 200
        return max(0, swing(frame, n, cycles, (i * 97) & 255, low, 1000))

    def drift(frame, n):
        return (frame * W // n, 0)                          # one width a loop, rightwards

    def shade(i, dist):
        """The i-th cloud pixel's own red, darkened as far from the moon as
        `dist` asks (`SHADE`)."""
        x, y, (base, _, _) = clouds[i]
        cap = next(((edge_top if ring.get((x, y)) == 0 else top) for far, top, edge_top in SHADE
                    if dist >= far), None)
        if cap is None or panel_red(base) <= panel_red(cap):
            return 1000
        return cap * 1000 // base + 1

    def cloud_light(frame, n, i, x, y):
        xx = (x + drift(frame, n)[0]) % W                   # where the pixel is drawn now
        dx = (max(0, xx - RIGHT_FROM) * STEP_RIGHT if xx >= MOON_CX
              else (MOON_CX - xx) * STEP_LEFT)
        dy = max(0, y - GLOW_Y) * STEP_Y
        dist = math.isqrt(dx * dx + dy * dy)
        k = ring.get((x, y))
        step = FIRST + dist // BAND + k if k is not None else len(ramp)
        if step >= len(ramp) or not brighter(step, i):
            return shade(i, dist)
        return (LIT + 10 * step) * 1000 // clouds[i][2][0] + 1

    layers = [
        Layer("stars", stars, twinkle, key="starTwinkle"),
        Layer("moon", moon),
        Layer("clouds", clouds, cloud_light, drift, key="cloudMotion", tint=moonlit),
    ]
    return PixelScene("moon", "Красный месяц", layers, FRAME_MS, CYCLE_FRAMES, tint=red)


def star_green(peak):
    """A bright star burns amber and cools to red as it dims (`panel_amber`
    drops the green below its red); a faint one stays red."""
    return 72 if peak >= 90 else 40 if peak >= 60 else 0


def moon_ramp():
    """The crescent's colours from its inner limb to its faint rim, exactly as
    the panel draws them."""
    return [(panel_red(r), panel_amber(panel_red(r), g), 0)
            for r, g, _ in (MOON_INK[k] for k in "0123Tg")]


def moonlit(r):
    """A cloud pixel's colour: the crescent's ramp step when the multiplier
    lifted it to `LIT` or above, else its own red (cloud inks stop at 64)."""
    if r >= LIT:
        ramp = moon_ramp()
        return ramp[min(len(ramp) - 1, (r - LIT) // 10)]
    return (panel_red(r), 0, 0)


def red(r):
    """The panel's own red for a design red — pure red, green and blue off
    (picked on the panel 2026-09-29: small green and blue read as other
    colours at low duty)."""
    return (panel_red(r), 0, 0)
