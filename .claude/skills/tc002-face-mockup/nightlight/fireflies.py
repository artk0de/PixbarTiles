"""Fireflies: a dark field where some twenty fireflies wander on slow loops and
glow up and out one by one. A big one wears a dim amber halo while it is at
its brightest; a small one is a single dot.

Every colour is an amber picked on the panel (`GLOW`): a firefly never
dims through red, and its core stays short of gold (the sheet's fireflies
read too golden). A pixel's design red names its step (`step * 20 + 10`).
"""
from nlengine import SIN, Layer, PixelScene, phase, ramp, sdiv

FRAME_MS = 100          # 10 cs
CYCLE_FRAMES = 240      # 24 s at 1×

# Picked on the TC002 2026-09-29 (see `embers.HEAT`): the dimmest amber is
# red 100 + green 40; below that green reads yellow-green.
GLOW = [None, (100, 40, 0), (160, 40, 0), (192, 72, 0), (255, 72, 0), (255, 100, 0)]

# (centre x, centre y, reach x, reach y, turns a loop x / y, phases x / y,
#  glows a loop, glow phase, big)
FLIES = [
    (6, 11, 4, 2, 1, 2, 0, 64, 3, 0, True),
    (21, 4, 6, 2, 1, 1, 90, 10, 2, 150, True),
    (34, 11, 5, 3, 2, 1, 30, 200, 3, 90, True),
    (46, 5, 4, 2, 1, 2, 170, 120, 2, 40, True),
    (2, 3, 2, 1, 1, 1, 40, 0, 4, 20, False),
    (13, 7, 4, 2, 1, 2, 200, 40, 3, 200, False),
    (15, 14, 5, 1, 1, 1, 10, 100, 2, 110, False),
    (27, 9, 5, 2, 2, 1, 120, 60, 4, 60, False),
    (30, 2, 4, 1, 1, 2, 80, 30, 3, 240, False),
    (40, 13, 4, 1, 1, 1, 220, 180, 2, 170, False),
    (43, 9, 3, 2, 2, 1, 60, 90, 3, 130, False),
    (50, 13, 2, 2, 1, 1, 140, 220, 4, 80, False),
    (10, 2, 3, 1, 2, 1, 5, 86, 4, 238, True),
    (26, 13, 3, 2, 1, 2, 222, 177, 2, 57, True),
    (4, 7, 2, 2, 2, 1, 139, 226, 3, 179, False),
    (18, 10, 4, 1, 2, 1, 106, 203, 2, 60, False),
    (23, 1, 5, 1, 2, 2, 220, 74, 3, 181, False),
    (31, 6, 5, 2, 2, 1, 66, 65, 4, 252, False),
    (37, 3, 3, 2, 2, 2, 250, 142, 2, 242, False),
    (38, 8, 5, 1, 2, 2, 101, 19, 3, 119, False),
    (48, 1, 2, 1, 1, 2, 228, 174, 3, 107, False),
    (20, 7, 2, 2, 2, 2, 213, 65, 3, 175, False),
]
# The triangle below zero is dark: lit 55 % of each glow (40 % left the
# field too empty — the user, 2026-09-29).
LIT_FROM = -800


def design(step):
    return (step * 20 + 10, 0, 0)


def glow(r):
    return GLOW[min(len(GLOW) - 1, r // 20)] if r >= 20 else (0, 0, 0)


def scene():
    layers = []
    for cx, cy, ax, ay, kx, ky, px, py, kp, pp, big in FLIES:
        core = 5 if big else 3
        pixels = [(cx, cy, design(core))]
        if big:
            pixels += [(cx + dx, cy + dy, design(1)) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]

        def wander(frame, n, ax=ax, ay=ay, kx=kx, ky=ky, px=px, py=py):
            return (sdiv(ax * SIN[phase(frame, n, kx, px)], 127),
                    sdiv(ay * SIN[phase(frame, n, ky, py)], 127))

        def pulse(frame, n, i, x, y, kp=kp, pp=pp):
            return max(0, ramp(frame, n, kp, pp, LIT_FROM, 1000))

        layers.append(Layer(f"fly{cx}", pixels, pulse, wander, key="flyMotion"))
    return PixelScene("fireflies", "Светлячки", layers, FRAME_MS, CYCLE_FRAMES, tint=glow)
