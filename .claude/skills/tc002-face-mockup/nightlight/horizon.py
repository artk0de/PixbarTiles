"""Warm horizon: the sheet's panel pixel for pixel, lit by the brief's slow
light (the user, 2026-09-29).

The picture is the traced sheet (`maps.MAPS["horizon"]`) quantised onto the
approved colours: a horizon line along the bottom, the band fading to dark
red within three rows, and a sun gone under at x 8…14 whose dome rises two
rows higher, near yellow at its foot. Everything above is black.

Nothing moves; only the light changes, slowly:
  wave   — 0.7·sin(x·0.10 + t·0.35) + 0.3·sin(x·0.23 − t·0.17): where it
           peaks a pixel above the line lifts a step, where it troughs it
           drops one — so only a few pixels change at a time and no stripe
           runs;
  sun    — the dome warms a step and cools back once a loop.
The horizon line never changes. Solid steps only: dithering read as dots on
this panel, and a whole area changing level at once read as flicker.
"""
from nlengine import SIN, W, H, Layer, PixelScene, phase, swing

FRAME_MS = 250          # 25 cs: 4 frames a second is plenty for light this slow
CYCLE_FRAMES = 144      # 36 s at 1×: the waves turn twice and once, whole

# The approved colours, 1 … 7, dimmest first.
LEVELS = [(40, 0, 0), (100, 0, 0), (160, 40, 0), (192, 40, 0), (255, 72, 0), (255, 100, 0), (255, 144, 0)]

# The sheet's panel on our levels: each traced cell's sheet colour
# (`ngen.ramp`) taken to the nearest approved one by RGB distance, rows
# 11 … 15. (Cutting the traced intensity at thresholds instead left the band
# two steps dimmer than the sheet — its 205 is orange, 255/100, not 192/40.)
BAND_Y = 11
BAND = [
    ".......11123222221..................................",
    "11.1.11122333222211.....11..........................",
    "221222222344444322222212222211111.1...1221..1.......",
    "2332223445667655533222234443222222111234322212222222",
    "5556566667777777666554555555545554444444444444444444",
]

# The waves: (SIN steps per column, turns a loop, sign, share per mille) —
# 0.10 rad a column ≈ 4 steps, 0.35 rad/s over 36 s ≈ 2 turns; the second
# runs the other way. Past ±PEAK a pixel above the line moves one step.
WAVES = [(4, 2, 1, 700), (9, 1, -1, 300)]
PEAK = 780
ROW_SHIFT = 23          # SIN steps a row: the fronts lean, so a column's rows never step together
JITTER = 160            # per mille either way, fixed per pixel: neighbours cross a threshold frames apart

# The sun's dome, round SUN_X: above the line it warms a step and cools back
# once a loop, from its middle outwards — a pixel SUN_REACH columns and rows
# off warms last — so a few pixels change at a time; a whole dome stepping
# at once changed 47 pixels in a frame, which the panel shows as a jolt.
SUN_X, SUN_REACH = 12, 6
SUN_START, SUN_SPREAD = 150, 130   # swing per mille the middle warms at, and per column / row off


def base(x, y):
    d = y - BAND_Y
    if not 0 <= d < len(BAND):
        return 0
    ch = BAND[d][x]
    return 0 if ch == "." else int(ch)


def jitter(x, y):
    """A fixed pseudo-random −JITTER … +JITTER per pixel."""
    h = ((x * 73856093) ^ (y * 19349663) ^ 0x5BD1E995) & 0xFFFFFFFF
    h = (h * 2654435761 & 0xFFFFFFFF) >> 16
    return h * 2 * JITTER // 0xFFFF - JITTER


def wave(frame, n, x, y):
    s = 0
    for step, turns, sign, share in WAVES:
        s += share * SIN[(x * step + y * ROW_SHIFT + sign * phase(frame, n, turns)) & 255] // 127
    return s + jitter(x, y)


def drawn(frame, n, x, y):
    """The level a pixel is drawn at, 0 for black."""
    lv = base(x, y)
    if y == H - 1 or not lv:
        return lv                                           # the horizon line and the sky never change
    v = wave(frame, n, x, y)
    shift = 1 if v > PEAK else -1 if v < -PEAK else 0
    off = max(abs(x - SUN_X), H - 2 - y)                    # columns or rows from the sun's foot
    warm_at = SUN_START + SUN_SPREAD * off + jitter(y, x) * SUN_SPREAD // (2 * JITTER)
    if off <= SUN_REACH and swing(frame, n, 1, 0, -1000, 1000) > warm_at:
        shift += 1
    return max(1, min(len(LEVELS), lv + max(-1, min(1, shift))))   # never more than a step off the sheet


def design(lv):
    return (lv * 20 + 10, 0, 0)


def tint(r):
    lv = r // 20
    return LEVELS[min(len(LEVELS), lv) - 1] if lv >= 1 else (0, 0, 0)


def scene():
    top = len(LEVELS)
    pixels = [(x, y, design(top)) for y in range(BAND_Y, H) for x in range(W) if base(x, y)]

    def light(frame, n, i, x, y):
        lv = drawn(frame, n, x, y)
        return (lv * 20 + 10) * 1000 // (top * 20 + 10) if lv else 0

    return PixelScene("horizon", "Тёплый горизонт", [Layer("band", pixels, light, key="horizonLight")],
                      FRAME_MS, CYCLE_FRAMES, tint=tint)
