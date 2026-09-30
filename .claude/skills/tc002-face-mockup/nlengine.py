"""The night-light animation engine: a scene is a stack of layers, each a set
of pixels with their base colours, drawn every frame as
`base colour × multiplier(frame)` at a whole-pixel offset.

No stored frames. A layer never changes its drawing: it only scales its
pixels' brightness and, for a drifting layer, moves the whole of it by whole
pixels, wrapping at the panel's edge. Everything happens on the 832 physical
pixels in integer arithmetic — no fractional coordinates, no filtering, no
blur — so the Swift engine reproduces every frame exactly.

A multiplier is per mille (1000 = the base colour as drawn). Multipliers and
offsets are asked with the frame index and the loop length `n` and must be
periodic in `n`, so the GIF loops without a seam at any animation speed.
"""
import math

W, H = 52, 16

# round(127·sin(2πi/256)); a literal on the Swift side, pinned by the fixture.
SIN = [int(round(127 * math.sin(2 * math.pi * i / 256))) for i in range(256)]


# The reds the TC002 tells apart, measured on the panel 2026-09-29: 4…64 light
# as one dimmest dot, 72…128 read as one, 144…255 step apart. A design red
# maps to the level of its band — (lowest design red, panel red); below the
# first band it is off.
PANEL_REDS = [(8, 40), (20, 100), (36, 144), (64, 160), (90, 176),
              (120, 192), (150, 224), (185, 255)]


def panel_red(r):
    level = 0
    for low, out in PANEL_REDS:
        if r >= low:
            level = out
    return level


def step_up(r, steps=1):
    """The lowest design red `steps` panel levels above `r`'s own."""
    lows = [low for low, _ in PANEL_REDS]
    band = sum(1 for low in lows if r >= low) - 1
    return lows[min(len(lows) - 1, band + steps)]


# The ambers picked on the panel 2026-09-29 (red 255…40 × green 0…144): each
# green shows only from this panel red up — below it the same green reads
# yellow-green. (green, lowest panel red), greenest first.
AMBER_FLOOR = [(144, 192), (100, 160), (72, 160), (40, 100)]


def panel_amber(r, g):
    """The greenest approved green at or below `g` that panel red `r` carries."""
    for green, floor in AMBER_FLOOR:
        if g >= green and r >= floor:
            return green
    return 0


def sdiv(a, b):
    """Division truncating toward zero — Swift's `/` — for signed operands."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def phase(frame, n, cycles, offset=0):
    """The SIN index at `cycles` whole turns per loop of `n` frames."""
    return (frame * cycles * 256 // n + offset) & 255


def swing(frame, n, cycles, offset, low, high):
    """A smooth periodic value from `low` to `high` per mille:
    low + (high − low)·(½ + ½·sin)."""
    s = SIN[phase(frame, n, cycles, offset)]                # −127 … 127
    return low + (high - low) * (s + 127) // 254


def ramp(frame, n, cycles, offset, low, high):
    """A triangle from `low` to `high` and back per mille: the same step every
    frame, so the change never stalls at the turns the way a sine does."""
    p = phase(frame, n, cycles, offset)
    t = p if p < 128 else 256 - p                           # 0 … 128
    return low + (high - low) * t // 128


def still(frame, n, i, x, y):
    return 1000


def fixed(frame, n):
    return (0, 0)


class Layer:
    """A named group of pixels and how it moves.

    `pixels` are (x, y, (r, g, b)) as drawn. `multiplier(frame, n, index, x, y)`
    answers per mille for the index-th pixel, `offset(frame, n)` the whole-pixel
    shift of the layer (x wraps round the panel, y clips). `key` names the
    setting that stops the layer's motion. A stopped layer holds its first
    frame (`holds="frame"`), or with `holds="position"` stays where it is
    and keeps its light — a firefly that stops flying still glows.
    Later layers draw over earlier ones. `tint`, when given, replaces the
    scene's for this layer."""

    def __init__(self, name, pixels, multiplier=still, offset=fixed, key=None, tint=None, holds="frame"):
        self.name, self.pixels, self.key, self.holds = name, pixels, key, holds
        self.multiplier, self.offset, self.tint = multiplier, offset, tint


class PixelScene:
    """`tint`, when given, makes the scene one hue: only the red channel is
    animated and `tint(r)` gives the pixel — so the GIF's palette is at most
    one colour per red level, and nothing drifts off the scene's hue. A base
    colour's green, when set, is an accent held fixed while red animates: the
    panel shows green only above its floor, so a scaled green would flicker
    between off and the floor. It shows only where the red carries it
    (`panel_amber`): a dimmed amber pixel turns red, never yellow-green."""

    def __init__(self, sid, name, layers, frame_ms, cycle_frames, tint=None):
        self.sid, self.name, self.layers = sid, name, layers
        self.frame_ms = frame_ms
        self.cycle_frames = cycle_frames      # the loop at 1× speed
        self.tint = tint

    def frames(self, speed=(1, 1)):
        """The loop's length at a speed num/den: 2× plays the same cycles in
        half the frames, ½× in twice as many."""
        num, den = speed
        return self.cycle_frames * den // num

    def render(self, frame, n, off=frozenset()):
        """One frame as rows of RGB or None; a layer whose key is in `off` is
        stopped (see `Layer`). It used to be drawn at full base with no
        offset, which lit every cell a silhouette-cutting layer could ever
        reach: the stopped fireplace and glow read as solid blocks."""
        grid = [[None] * W for _ in range(H)]
        for layer in self.layers:
            stopped = layer.key in off
            dx, dy = layer.offset(0 if stopped else frame, n)
            lit_at = 0 if stopped and layer.holds == "frame" else frame
            tint = layer.tint or self.tint
            for i, (x, y, c) in enumerate(layer.pixels):
                m = layer.multiplier(lit_at, n, i, x, y)
                xx, yy = (x + dx) % W, y + dy
                if not 0 <= yy < H:
                    continue
                if tint:
                    r = min(255, c[0] * m // 1000)
                    out = tint(r) if r else (0, 0, 0)
                    if r and c[1]:
                        out = (out[0], panel_amber(out[0], c[1]), out[2])
                else:
                    out = tuple(min(255, ch * m // 1000) for ch in c)
                if any(out):
                    grid[yy][xx] = out
        return grid


def mask(rows, colours, x0=0, y0=0):
    """A character mask as layer pixels: each character names a colour in
    `colours`, '.' is empty."""
    return [(x0 + dx, y0 + dy, colours[ch]) for dy, row in enumerate(rows)
            for dx, ch in enumerate(row) if ch != "."]
