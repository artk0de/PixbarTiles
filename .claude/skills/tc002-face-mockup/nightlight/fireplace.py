"""Fireplace: the sheet's small fire pixel for pixel, set alive by the
user's brief (2026-09-29) — the liveliest scene, still a night light.

The picture is the sheet's panel (`out/sheet-52x16.json`), each cell taken
to the nearest approved colour by RGB distance: a loose fire round x 27 —
a narrow hot core, a red body with dark holes and side licks, a sparse
bed of embers below — with its core held at amber, 255/100: the brief asks
for no yellow centre at night.

  embers — the bottom two rows; each ember swings a step and back on its own
           2–5 s period, so only a few change at a time;
  flames — every column above them slides its own cells up and down,
           −1 … +2 rows, on an energy that drifts smoothly (two sines, their
           phase rolling along the row so the silhouette flows): the tongues'
           tops rise and fall, the holes in the body move with them;
  sparks — at most three single pixels at once, each rising a row every
           400 ms from the core's top, fading to nothing and drifting aside.
"""
from nlengine import SIN, W, H, Layer, PixelScene, phase, sdiv, swing

FRAME_MS = 100          # 10 cs: 10 frames a second, as the brief asks for a fire
CYCLE_FRAMES = 200      # 20 s at 1×

# The approved colours, 1 … 8, by brightness: pure reds first — the sheet's
# flame body is red; without 160 and 192 red its cells fell to orange 160/40
# and the fire read orange — then the ambers.
LEVELS = [(40, 0, 0), (100, 0, 0), (160, 0, 0), (192, 0, 0), (160, 40, 0), (192, 40, 0), (255, 72, 0),
          (255, 100, 0)]
TOP_LEVEL = 8           # 255/100: the sheet's near-yellow core (253, 180, 88) is held at amber

# The sheet's panel on our levels, rows FIRE_Y … 15 (its sparks at rows 3
# and 5 are left to the spark layer); its 255/144 core cells read 8.
FIRE_Y = 6
FIRE = [
    ".....................3......3.......................",
    ".....................2..541.3.......................",
    "........................56331.3.....................",
    "......................22.2651.5.....................",
    "..................22..2324875.3.1...................",
    "..................33.1323688614.2...1...............",
    "..................22.233488862312...2...............",
    "..............2.126653668888868342221...............",
    "............122328777318888752825763213..1..........",
    "............122.28.22.2773652.6.586...3....1........",
]
EMBER_ROWS = 2          # the bottom two rows are the bed
EMBER_TURNS = [4, 5, 7, 9, 6, 8]        # turns a loop: 2.2 … 5 s a swing

ENERGY = [(7, 1000), (13, 500)]         # (turns a loop, weight): 2.9 s and 1.5 s swells
ROLL = 37               # SIN steps of phase from one column to the next
LIFT_BIAS, LIFT_SCALE = 300, 750        # energy → rows the column slides: (e + bias) / scale, −1 … +2

# (slot turns a loop, first frame, column, drift over its rise).
SPARKS = [(4, 11, 26, 1), (2, 67, 29, -1), (5, 30, 27, 1)]
SPARK_ROW = 4           # frames a row: 400 ms
SPARK_LEVELS = [7, 6, 3, 2]


def base(x, y):
    d = y - FIRE_Y
    if not 0 <= d < len(FIRE):
        return 0
    ch = FIRE[d][x]
    return 0 if ch == "." else min(TOP_LEVEL, int(ch))


def lift(frame, n, x):
    """Rows the column's cells slide up this frame, −1 … +2."""
    e = 0
    for turns, weight in ENERGY:
        e += weight * SIN[(phase(frame, n, turns) + x * ROLL * turns) & 255] // 127
    return max(-1, min(2, sdiv(e + LIFT_BIAS, LIFT_SCALE)))


def flame_level(frame, n, x, y):
    """A flame cell's level: the sheet's cell `lift` rows below it."""
    root = H - 1 - EMBER_ROWS                               # the flames' lowest row
    src = y + lift(frame, n, x)
    return base(x, min(root, src)) if src >= FIRE_Y else 0


def design(lv):
    return (lv * 20 + 10, 0, 0)


def tint(r):
    lv = r // 20
    return LEVELS[min(len(LEVELS), lv) - 1] if lv >= 1 else (0, 0, 0)


def per_mille(lv, of):
    return (lv * 20 + 10) * 1000 // (of * 20 + 10) if lv else 0


def top_of(frame, n, x):
    """The row above the column's top flame cell this frame."""
    for y in range(FIRE_Y - 2, H - EMBER_ROWS):
        if flame_level(frame, n, x, y):
            return y - 1
    return H - EMBER_ROWS - 1


def scene():
    embers = [(x, y, design(base(x, y))) for y in range(H - EMBER_ROWS, H) for x in range(W) if base(x, y)]

    def smoulder(frame, n, i, x, y):
        lv = embers[i][2][0] // 20
        turns = EMBER_TURNS[(x + y) % len(EMBER_TURNS)]
        s = swing(frame, n, turns, (x * 97 + y * 41) & 255, -1000, 1000)
        return per_mille(max(1, min(TOP_LEVEL, lv + (1 if s > 600 else -1 if s < -600 else 0))), lv)

    cols = [x for x in range(W) if any(base(x, y) for y in range(FIRE_Y, H - EMBER_ROWS))]
    flames = [(x, y, design(TOP_LEVEL)) for y in range(FIRE_Y - 2, H - EMBER_ROWS) for x in cols]

    def burn(frame, n, i, x, y):
        return per_mille(flame_level(frame, n, x, y), TOP_LEVEL)

    layers = [Layer("embers", embers, smoulder, key="flames"), Layer("flames", flames, burn, key="flames")]
    for turns, start, x0, drift in SPARKS:
        def life(frame, n, turns=turns, start=start):
            u = (frame * CYCLE_FRAMES // n + start) % (CYCLE_FRAMES // turns)
            s = u // SPARK_ROW
            return s if s < len(SPARK_LEVELS) else None

        def rise(frame, n, life=life, x0=x0, drift=drift):
            s = life(frame, n)
            if s is None:
                return (-99, -99)
            return (drift * s // (len(SPARK_LEVELS) - 1), top_of(frame, n, x0) - s)

        def fade(frame, n, i, x, y, life=life):
            s = life(frame, n)
            return 0 if s is None else per_mille(SPARK_LEVELS[s], SPARK_LEVELS[0])

        layers.append(Layer(f"spark{x0}", [(x0, 0, design(SPARK_LEVELS[0]))], fade, rise, key="sparks"))
    return PixelScene("fireplace", "Камин", layers, FRAME_MS, CYCLE_FRAMES, tint=tint)
