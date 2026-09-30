"""Embers: a bed of coals along the bottom rows, dark crusts over glowing
cores, the seams between lumps hotter; its glowing pixels flicker one heat
step and back, and sparks leave the bed, rise a few rows and cool on the way.

Every colour is one of the reds and ambers picked on the panel (`HEAT`).
A pixel's design red names its heat step (`step * 20 + 10`), so the engine's
per-mille multiplier moves it between whole steps and never between hues
the panel was not shown.
"""
from nlengine import Layer, PixelScene, mask, swing

FRAME_MS = 100          # 10 cs
CYCLE_FRAMES = 200      # 20 s at 1×; a spark climbs a row every 4 frames (2 at 2×, 8 at ½×)
ROW_TIME = 4            # 1× frames a spark takes per row

# The amber steps picked on the TC002 2026-09-29 (a grid of red 255…40 ×
# green 0…144): pure red at every level, green 40 down to red 100, green
# 72 and 100 down to red 160, green 144 at red 255 and 192 only — any more
# green at a lower red read yellow-green. Heat 1 is the crust, 8 the core.
HEAT = [None, (40, 0, 0), (100, 0, 0), (160, 0, 0), (192, 0, 0),
        (255, 40, 0), (255, 72, 0), (255, 100, 0), (255, 144, 0)]

# `make_embers.py`, seed 0xE3B: heat digits on rows 10…15.
BED_Y = 10
BED = [
    "....................................................",
    "..........................21........................",
    ".11........11......1111211231.......................",
    "1221......124......2222234334...111111212111111.2211",
    "2686.1121.866111211434368643511133222242222242212222",
    "4456133331447368645544444668633644444464544464455544",
]

# (x, sparks a loop, start in 1× frames, rows it climbs, columns it drifts)
SPARKS = [
    (3, 4, 7, 5, 0), (10, 2, 31, 8, 1), (17, 5, 12, 4, 0), (24, 4, 40, 7, -1),
    (27, 2, 83, 9, 0), (33, 5, 22, 6, 1), (39, 4, 3, 5, 0), (44, 2, 58, 8, -1),
    (49, 5, 29, 6, 0), (14, 4, 19, 6, 0),
]
SPARK_HEAT = 7          # a spark leaves the bed at heat 7 and cools to 2
# From this heat up every pixel flickers, down two steps and back: a still
# yellow-amber dot read as a fault (the user, 2026-09-29, on the panel).
HOT = 6


def design(step):
    return (step * 20 + 10, 0, 0)


def per_mille(to_step, from_step):
    """The multiplier that shows a pixel of heat `from_step` at `to_step`."""
    return (to_step * 20 + 10) * 1000 // (from_step * 20 + 10) if to_step else 0


def heat(r):
    return HEAT[min(len(HEAT) - 1, r // 20)] if r >= 20 else (0, 0, 0)


def scene():
    inks = {str(s): design(s) for s in range(1, 9)}
    bed = mask(BED, inks, 0, BED_Y)
    tops = {x: min(y for xx, y, _ in bed if xx == x) for x in range(52) if any(xx == x for xx, _, _ in bed)}

    def flicker(frame, n, i, x, y):
        step = bed[i][2][0] // 20
        h = (x * 73 + y * 151) & 255
        if step >= HOT:                              # every hot spot flickers, two steps deep
            low = per_mille(step - 2, step)
        elif step < 2 or h % 3:                      # a third of the other glowing pixels flicker
            return 1000
        else:
            low = per_mille(step - 1, step)
        return swing(frame, n, 2 + h % 4, h, low - 150, 1000 + 40)

    layers = [Layer("bed", bed, flicker, key="emberGlow")]
    for x, k, start, rise, drift in SPARKS:
        y0 = tops[x] - 1
        period = CYCLE_FRAMES // k

        def climbed(frame, n, period=period, start=start, rise=rise):
            u = (frame * CYCLE_FRAMES // n + start) % period      # 1× frames into this spark
            s = u // ROW_TIME
            return s if s < rise else None

        def offset(frame, n, climbed=climbed, rise=rise, drift=drift):
            s = climbed(frame, n)
            return (-99, -99) if s is None else (drift * s // rise, -s)

        def glow(frame, n, i, x, y, climbed=climbed, rise=rise):
            s = climbed(frame, n)
            if s is None:
                return 0
            head = SPARK_HEAT - 5 * s // rise
            if i == 0:
                return per_mille(head, SPARK_HEAT)
            return per_mille(max(0, head - 4), SPARK_HEAT) if s else 0

        pixels = [(x, y0, design(SPARK_HEAT)), (x, y0 + 1, design(SPARK_HEAT))]
        layers.append(Layer(f"spark{x}", pixels, glow, offset, key="sparks"))
    return PixelScene("embers", "Тлеющие угли", layers, FRAME_MS, CYCLE_FRAMES, tint=heat)
