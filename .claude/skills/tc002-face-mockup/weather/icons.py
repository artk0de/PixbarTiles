"""16x16 animated weather icons for the TC002, as pure pixel frames.

Each icon is a list of (frame, ms) where a frame is a 16x16 grid of RGB
tuples or None (unlit). Shapes are laid down from a few primitives — discs,
a cloud union, sprites — so a whole family shares one cloud and one sun, and
the motion (rays breathing, drops falling, a bolt striking) is written as
frame arithmetic rather than hand-copied frames.
"""

S = 16


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


C = {k: hexrgb(v) for k, v in {
    "sun": "#FFD23A", "sun_edge": "#FF9F1C", "ray": "#FFB52E", "ray_dim": "#8A5A10",
    "moon": "#F4EBB8", "moon_edge": "#B8AC72", "star": "#FFFFFF", "star_dim": "#5A5A70",
    "cl_hi": "#FFFFFF", "cl": "#D5DBE5", "cl_lo": "#8E98A8",
    "dk_hi": "#A9B2C0", "dk": "#78818F", "dk_lo": "#4E5563",
    "nt_hi": "#9AA4B8", "nt": "#6C7588", "nt_lo": "#444B5C",
    "drop": "#4DA6FF", "drop_tail": "#1F5FB8", "drizzle": "#7CC4FF",
    "snow": "#FFFFFF", "snow_dim": "#9FB4CC",
    "ice": "#8EE6FF", "ice_dim": "#3A8FB0",
    "fog": "#B3BAC6", "fog_dim": "#6E7684",
    "bolt": "#FFE14D", "bolt_core": "#FFFFFF",
    "hum": "#3BA0FF", "hum_lo": "#1C5FA8", "hum_hi": "#A8DAFF", "hum_empty": "#0E2A4A",
    "wind": "#CFE8F0", "wind_dim": "#5E7C88",
    "therm": "#E8E8E8", "therm_hot": "#FF5A3C", "therm_cold": "#3C9CFF",
}.items()}


def blank():
    return [[None] * S for _ in range(S)]


def put(f, x, y, c):
    if 0 <= x < S and 0 <= y < S and c is not None:
        f[y][x] = c


def sprite(f, rows, x, y, c):
    for dy, row in enumerate(rows):
        for dx, ch in enumerate(row):
            if ch == "#":
                put(f, x + dx, y + dy, c)


def disc(f, cx, cy, r, core, edge):
    for y in range(S):
        for x in range(S):
            d2 = (x - cx) ** 2 + (y - cy) ** 2
            if d2 <= r * r:
                put(f, x, y, edge if d2 > (r - 1.1) ** 2 else core)


# ---- cloud: one union of circles on a flat base, lit from the top ----------

CLOUD_BIG = [(5.0, 3.6, 3.4), (9.4, 4.6, 2.9), (2.4, 5.6, 2.2), (12.0, 6.0, 1.9)]
CLOUD_SMALL = [(3.6, 2.6, 2.5), (6.8, 3.4, 2.1), (1.6, 4.0, 1.6), (8.8, 4.2, 1.4)]


def cloud_mask(circles, base, x0, x1):
    def inside(x, y):
        if y > base:
            return False
        if any((x - cx) ** 2 + (y - cy) ** 2 <= r * r for cx, cy, r in circles):
            return True
        return x0 <= x <= x1 and y >= base - 2
    return inside


def cloud(f, ox, oy, tone="cl", size="big"):
    if size == "big":
        inside = cloud_mask(CLOUD_BIG, 7, 1, 13)
        w, h = 15, 8
    else:
        inside = cloud_mask(CLOUD_SMALL, 5, 0, 9)
        w, h = 11, 6
    hi, mid, lo = C[tone + "_hi"], C[tone], C[tone + "_lo"]
    for y in range(h):
        for x in range(w):
            if not inside(x, y):
                continue
            if not inside(x, y - 1):
                c = hi
            elif not inside(x, y + 1):
                c = lo
            else:
                c = mid
            put(f, ox + x, oy + y, c)


# ---- suns and moons ----------------------------------------------------------

def sun(f, cx, cy, r, phase, ray_len=2):
    """Rays breathe: orthogonal and diagonal rays trade length with `phase`."""
    disc(f, cx, cy, r, C["sun"], C["sun_edge"])
    ortho = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    diag = [(1, -1), (1, 1), (-1, 1), (-1, -1)]
    long_o = phase in (0, 1)
    long_d = phase in (1, 2)
    for dx, dy in ortho:
        n = ray_len if long_o else ray_len - 1
        for k in range(n):
            d = r + 1.6 + k
            put(f, round(cx + dx * d - 0.5 + (0.5 if dx == 0 else 0)), round(cy + dy * d - 0.5 + (0.5 if dy == 0 else 0)),
                C["ray"] if k == 0 or long_o else C["ray_dim"])
    for dx, dy in diag:
        n = ray_len - 1 if long_d else 1
        for k in range(max(n, 1)):
            d = (r + 1.2 + k) / 1.414
            put(f, round(cx + dx * d), round(cy + dy * d), C["ray"] if long_d or k == 0 else C["ray_dim"])


def moon(f, cx, cy, r, cut_dx, cut_dy, cut_r):
    for y in range(S):
        for x in range(S):
            d2 = (x - cx) ** 2 + (y - cy) ** 2
            if d2 <= r * r and (x - cx - cut_dx) ** 2 + (y - cy - cut_dy) ** 2 > cut_r * cut_r:
                edge = d2 > (r - 1.1) ** 2
                put(f, x, y, C["moon_edge"] if edge else C["moon"])


def star(f, x, y, level):
    """level 0 off, 1 dim dot, 2 bright dot, 3 bright cross."""
    if level == 0:
        return
    put(f, x, y, C["star"] if level >= 2 else C["star_dim"])
    if level == 3:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            put(f, x + dx, y + dy, C["star_dim"])


# ---- precipitation ---------------------------------------------------------

def drops(f, t, columns, top, bottom, length, speed, head, tail):
    span = bottom - top + 1 + length
    for col, off in columns:
        y = top + (t * speed + off) % span - length
        for k in range(length):
            yy = y + k
            if top <= yy <= bottom:
                put(f, col, yy, head if k == length - 1 else tail)


def flakes(f, t, seeds, top, bottom):
    span = bottom - top + 1
    for x0, off, wob in seeds:
        y = top + (t + off) % span
        x = x0 + (1 if (t + wob) % 4 < 2 else 0)
        put(f, x, y, C["snow"] if (t + off) % 3 else C["snow_dim"])


BOLT = ["...##",
        "..##.",
        ".##..",
        "####.",
        "..##.",
        ".##..",
        ".#...",
        "#...."]


def bolt(f, x, y, bright):
    sprite(f, BOLT, x, y, C["bolt_core"] if bright else C["bolt"])
    if bright:
        sprite(f, BOLT, x + 1, y, C["bolt"])


# ---- icons -------------------------------------------------------------------

def clear_day():
    out = []
    for p in range(4):
        f = blank()
        sun(f, 7.5, 7.5, 3.9, p, ray_len=2)
        out.append((f, 300))
    return out


def clear_night():
    levels = [(1, 2, 3, 2, 1, 1), (2, 1, 1, 2, 3, 2), (3, 2, 1, 1, 1, 2)]
    pos = [(12, 2), (14, 8), (11, 13)]
    out = []
    for t in range(6):
        f = blank()
        moon(f, 6.5, 8.0, 5.8, 3.4, -2.6, 4.9)
        for (x, y), lv in zip(pos, levels):
            star(f, x, y, lv[t])
        out.append((f, 350))
    return out


def partly_cloudy(night):
    out = []
    drift = [0, 0, 1, 1, 1, 1, 0, 0]
    for t in range(8):
        f = blank()
        if night:
            moon(f, 5.5, 5.5, 4.4, 2.6, -2.0, 3.8)
            star(f, 13, 2, (3, 2, 1, 1, 2, 3, 2, 1)[t])
        else:
            sun(f, 5.5, 5.5, 3.5, t % 4, ray_len=2)
        cloud(f, 1 + drift[t], 8, "nt" if night else "cl")
        out.append((f, 280))
    return out


def cloudy(night):
    out = []
    back = [0, 0, -1, -1, -1, -1, 0, 0]
    front = [0, 0, 1, 1, 1, 1, 0, 0]
    for t in range(8):
        f = blank()
        if night:
            star(f, 2, 2, (1, 2, 3, 2, 1, 1, 1, 1)[t])
        cloud(f, 5 + back[t], 1, "nt" if night else "dk", "small")
        cloud(f, 0 + front[t], 7, "nt" if night else "cl")
        out.append((f, 300))
    return out


def fog():
    bars = [(2, 1, 11), (5, 3, 12), (8, 0, 10), (11, 2, 12), (14, 1, 9)]
    out = []
    for t in range(8):
        f = blank()
        for i, (y, x, n) in enumerate(bars):
            shift = [0, 1, 1, 0, 0, -1, -1, 0][(t + i * 2) % 8]
            for k in range(n):
                put(f, x + k + shift, y, C["fog"] if i % 2 == 0 else C["fog_dim"])
        out.append((f, 220))
    return out


def rain(heavy=False, tone="cl"):
    cols = [(2, 0), (5, 5), (8, 2), (11, 7), (14, 3)] if heavy else [(3, 0), (7, 4), (11, 2)]
    out = []
    for t in range(8):
        f = blank()
        cloud(f, 0, 0, tone)
        drops(f, t, cols, 9, 15, 3 if heavy else 2, 2 if heavy else 1,
              C["drop"], C["drop_tail"])
        out.append((f, 90 if heavy else 130))
    return out


def drizzle():
    cols = [(3, 0), (6, 3), (9, 1), (12, 4)]
    out = []
    for t in range(6):
        f = blank()
        cloud(f, 0, 0, "cl")
        span = 6
        for col, off in cols:
            y = 9 + (t + off) % span
            put(f, col, y, C["drizzle"])
        out.append((f, 200))
    return out


def snow():
    seeds = [(2, 0, 0), (6, 4, 1), (10, 2, 2), (13, 6, 3), (4, 5, 2), (8, 1, 3)]
    out = []
    for t in range(8):
        f = blank()
        cloud(f, 0, 0, "cl")
        flakes(f, t, seeds, 9, 15)
        out.append((f, 200))
    return out


FLAKE = [".....#.....",
         "..#..#..#..",
         "...#.#.#...",
         "....###....",
         ".#...#...#.",
         "###########",
         ".#...#...#.",
         "....###....",
         "...#.#.#...",
         "..#..#..#..",
         ".....#....."]
TIPS = [(5, 0), (8, 1), (10, 5), (8, 9), (5, 10), (2, 9), (0, 5), (2, 1)]


def frost():
    out = []
    for t in range(8):
        f = blank()
        sprite(f, FLAKE, 2, 2, C["ice_dim"])
        # the frost creeps: a bright wave runs out along the arms
        for y, row in enumerate(FLAKE):
            for x, ch in enumerate(row):
                if ch == "#":
                    ring = max(abs(x - 5), abs(y - 5))
                    if ring == t % 6 or ring == (t + 3) % 6:
                        put(f, 2 + x, 2 + y, C["ice"])
        tx, ty = TIPS[t]
        put(f, 2 + tx, 2 + ty, C["star"])
        out.append((f, 170))
    return out


def thunder(storm=False):
    seq = [(0, 500), (2, 70), (0, 70), (1, 220), (0, 600)]
    out = []
    t = 0
    for strike, ms in seq:
        steps = max(1, ms // 90) if storm else 1
        for _ in range(steps):
            f = blank()
            cloud(f, 0, 0, "dk" if strike == 0 else "cl")
            if storm:
                drops(f, t, [(2, 0), (13, 3), (4, 5), (11, 1)], 9, 15, 3, 2,
                      C["drop"], C["drop_tail"])
            if strike:
                bolt(f, 5, 8, strike == 2)
            out.append((f, ms // steps))
            t += 1
    return out


# ---- page icons (details the face can rotate through) -----------------------

DROP = ["......##......",
        ".....####.....",
        "....######....",
        "...########...",
        "..##########..",
        ".############.",
        ".############.",
        "##############",
        "##############",
        "##############",
        ".############.",
        "..##########..",
        "....######...."]


def humidity(level):
    """A drop that fills to `level` percent with a rippling surface."""
    out = []
    filled = 12 - round(level / 100 * 11)
    for t in range(6):
        f = blank()
        for y, row in enumerate(DROP):
            for x, ch in enumerate(row):
                if ch != "#":
                    continue
                edge = (x == 0 or row[x - 1] != "#" or x == len(row) - 1 or row[x + 1] != "#"
                        or y == 0 or DROP[y - 1][x] != "#" or y == len(DROP) - 1 or DROP[y + 1][x] != "#")
                surface = filled + (1 if (x + t) % 6 < 3 else 0)
                if y >= surface:
                    c = C["hum_hi"] if y == surface else C["hum"]
                else:
                    c = C["hum_lo"] if edge else C["hum_empty"]
                put(f, 1 + x, 2 + y, c)
        out.append((f, 180))
    return out


WIND_LINES = [(3, 1, 10, True), (7, 3, 12, False), (11, 0, 9, True)]


def wind():
    out = []
    for t in range(8):
        f = blank()
        for i, (y, x, n, curl) in enumerate(WIND_LINES):
            off = (t + i * 3) % 8
            for k in range(n):
                lit = (k - off) % 8 < 5
                put(f, x + k, y, C["wind"] if lit else C["wind_dim"])
            if curl:
                ex = x + n
                put(f, ex, y - 1, C["wind"])
                put(f, ex + 1, y - 2, C["wind"])
                put(f, ex, y - 3, C["wind_dim"])
        out.append((f, 120))
    return out


THERM = [".###.",
         ".#.#.",
         ".#.#.",
         ".#.#.",
         ".#.#.",
         ".#.#.",
         ".#.#.",
         ".#.#.",
         "##.##",
         "#...#",
         "#...#",
         "##.##",
         ".###."]


def thermometer(warm):
    out = []
    ink = C["therm_hot"] if warm else C["therm_cold"]
    for t in range(6):
        f = blank()
        sprite(f, THERM, 5, 1, C["therm"])
        level = 5 + (0, 1, 2, 2, 1, 0)[t]
        for y in range(13 - level, 13):
            put(f, 7, y, ink)
        for y in range(10, 12):
            for x in range(6, 9):
                put(f, x, y, ink)
        for k, y in enumerate((3, 6, 9)):
            put(f, 11, y, C["therm"] if k % 2 == 0 else C["star_dim"])
            put(f, 12, y, C["star_dim"])
        out.append((f, 220))
    return out


THEMES = {
    "clearDay": clear_day, "clearNight": clear_night,
    "partlyCloudyDay": lambda: partly_cloudy(False), "partlyCloudyNight": lambda: partly_cloudy(True),
    "cloudDay": lambda: cloudy(False), "cloudNight": lambda: cloudy(True),
    "fog": fog, "drizzle": drizzle, "rain": rain, "snow": snow, "frost": frost,
    "thunder": thunder, "storm": lambda: thunder(True),
}
PAGE_ICONS = {
    "humidity": lambda: humidity(70), "wind": wind,
    "feelsWarm": lambda: thermometer(True), "feelsCold": lambda: thermometer(False),
}


# =============================================================================
# Wave 2: every WMO state Open-Meteo can send, plus states derived from wind,
# temperature and the moon's age.
# =============================================================================

import math

C.update({k: hexrgb(v) for k, v in {
    "streak": "#F2FAFF", "streak_dim": "#8AAAB8", "frost_ray": "#9FDCF0", "frost_ray_dim": "#3F7A90",
    "hail": "#F2F8FF", "hail_dim": "#8FA6BF",
    "hot": "#FF6A1C", "hot_core": "#FFD84A", "shimmer": "#FF8C3A", "shimmer_dim": "#6A2A08",
    "cold_sun": "#FFF2B0", "cold_edge": "#C9D8E8",
    "earthshine": "#262634",
    "horizon": "#8A6A3A", "umbrella": "#FF4F6D", "umbrella_dk": "#A82A40", "handle": "#C8C8C8",
    "uv": "#B45AFF", "uv_dim": "#5A2A88",
}.items()})


def streaks(f, t, lines):
    """Wind: short bright dashes racing left to right. lines = [(y, len, speed, off)]."""
    for y, n, speed, off in lines:
        x0 = (t * speed + off) % (S + n) - n
        for k in range(n):
            put(f, x0 + k, y, C["streak"] if k >= n - 2 else C["streak_dim"])


def slanted(f, t, columns, top, bottom, length, speed, head, tail, slant=1):
    """Rain driven by wind: each drop moves `slant` px left per `speed` px down."""
    span = bottom - top + 1 + length
    for col, off in columns:
        p = (t * speed + off) % span
        for k in range(length):
            y = top + p - length + k
            x = col - (p - length + k) // 2 * slant
            if top <= y <= bottom:
                put(f, x, y, head if k == length - 1 else tail)


def mainly_clear(night):
    out = []
    drift = [0, 0, 1, 1, 2, 2, 1, 1]
    for t in range(8):
        f = blank()
        if night:
            moon(f, 6.5, 6.5, 5.2, 3.0, -2.4, 4.4)
            star(f, 14, 2, (1, 2, 3, 2, 1, 1, 2, 1)[t])
        else:
            sun(f, 6.5, 6.5, 3.6, t % 4, ray_len=2)
        cloud(f, 5 + drift[t], 10, "nt" if night else "cl", "small")
        out.append((f, 300))
    return out


def windy(kind):
    lines = [(9, 8, 3, 0), (11, 10, 2, 7), (13, 7, 3, 11), (15, 9, 2, 4)]
    out = []
    for t in range(10):
        f = blank()
        if kind == "day":
            sun(f, 5.5, 4.5, 3.2, t % 4, ray_len=1)
        elif kind == "night":
            moon(f, 5.0, 4.5, 4.0, 2.4, -1.8, 3.4)
        else:
            cloud(f, (0, 0, 1, 1, 1, 0, 0, -1, -1, -1)[t], 0, "cl")
        streaks(f, t, lines if kind != "cloud" else [(10, 9, 3, 0), (12, 11, 2, 7), (14, 8, 3, 11)])
        out.append((f, 80))
    return out


def showers(night, snow_=False):
    out = []
    for t in range(8):
        f = blank()
        if night:
            moon(f, 11.0, 4.0, 3.8, -2.2, -1.6, 3.2)
        else:
            sun(f, 11.0, 4.0, 3.0, t % 4, ray_len=1)
        cloud(f, 0, 3, "cl")
        if snow_:
            flakes(f, t, [(2, 0, 0), (6, 3, 1), (10, 1, 2), (13, 4, 3)], 12, 15)
        else:
            drops(f, t, [(3, 0), (7, 2), (11, 1)], 12, 15, 2, 1, C["drop"], C["drop_tail"])
        out.append((f, 150))
    return out


def heavy_rain():
    out = []
    for t in range(8):
        f = blank()
        cloud(f, 0, 0, "dk")
        slanted(f, t, [(3, 0), (6, 4), (9, 2), (12, 6), (15, 3), (5, 7), (11, 5)], 8, 15, 3, 2,
                C["drop"], C["drop_tail"])
        out.append((f, 70))
    return out


def blizzard():
    out = []
    seeds = [(4, 0), (8, 3), (12, 1), (15, 5), (6, 6), (10, 2), (14, 7), (2, 4)]
    for t in range(10):
        f = blank()
        cloud(f, 0, 0, "dk")
        for x0, off in seeds:
            p = (t + off) % 8
            put(f, x0 - p, 8 + p, C["snow"] if (t + off) % 3 else C["snow_dim"])
        streaks(f, t, [(11, 4, 3, 5), (14, 5, 3, 0)])
        out.append((f, 90))
    return out


def sleet():
    out = []
    for t in range(8):
        f = blank()
        cloud(f, 0, 0, "cl")
        drops(f, t, [(3, 0), (11, 4)], 9, 15, 2, 1, C["drop"], C["drop_tail"])
        flakes(f, t, [(6, 2, 0), (13, 6, 2)], 9, 15)
        out.append((f, 150))
    return out


def freezing_rain():
    """Drops fall blue and land as ice: a glittering glaze on the ground."""
    out = []
    for t in range(8):
        f = blank()
        cloud(f, 0, 0, "cl")
        drops(f, t, [(3, 0), (7, 3), (11, 1)], 9, 14, 2, 1, C["ice"], C["ice_dim"])
        for x in range(1, 15):
            put(f, x, 15, C["star"] if (x + t * 3) % 7 == 0 else C["ice_dim"])
        out.append((f, 140))
    return out


def hail():
    """Thunderstorm with hail: pellets bounce off the ground, the bolt strikes."""
    out = []
    for t in range(10):
        f = blank()
        strike = t in (6, 7)
        cloud(f, 0, 0, "cl" if strike else "dk")
        for col, off in ((3, 0), (8, 3), (12, 6), (6, 8)):
            p = (t * 2 + off) % 10
            y = 9 + p if p <= 6 else 15 - (p - 6)   # fall, then a small bounce
            put(f, col + (1 if p > 6 else 0), y, C["hail"])
        if strike:
            bolt(f, 9, 8, t == 6)
        out.append((f, 110))
    return out


def rime_fog():
    out = []
    base = fog()
    sparks = [(3, 3), (12, 6), (6, 9), (14, 12), (2, 13)]
    for t, (f, ms) in enumerate(base):
        g = [row[:] for row in f]
        for i, (x, y) in enumerate(sparks):
            if (t + i * 2) % 5 == 0:
                put(g, x, y, C["star"])
            elif (t + i * 2) % 5 == 1:
                put(g, x, y, C["ice"])
        out.append((g, ms))
    return out


def hot():
    """Heat: a swollen red sun and air shimmering above the ground."""
    out = []
    for t in range(8):
        f = blank()
        disc(f, 7.5, 6.0, 4.6, C["hot_core"], C["hot"])
        for k, (dx, dy) in enumerate([(0, -1), (1, -1), (1, 0), (-1, -1), (-1, 0)]):
            d = 6.4 if (t + k) % 2 else 5.8
            put(f, round(7.5 + dx * d / (1.414 if dx and dy else 1)), round(6 + dy * d / (1.414 if dx and dy else 1)), C["hot"])
        for row, y in enumerate((12, 14)):
            for x in range(1, 15):
                wave = math.sin((x + t * 1.0 + row * 2) * 0.9)
                put(f, x, y + (1 if wave > 0.4 else 0), C["shimmer"] if wave > -0.2 else C["shimmer_dim"])
        out.append((f, 140))
    return out


def frosty_clear():
    """Clear and freezing: a pale winter sun, ice crystals glinting around it."""
    out = []
    glints = [(1, 2), (14, 3), (13, 13), (2, 12), (8, 15)]
    for t in range(6):
        f = blank()
        sun(f, 7.5, 7.5, 3.9, t % 4, ray_len=2)
        for y in range(S):
            for x in range(S):
                v = f[y][x]
                f[y][x] = {C["sun"]: C["cold_sun"], C["sun_edge"]: C["cold_edge"],
                           C["ray"]: C["frost_ray"], C["ray_dim"]: C["frost_ray_dim"]}.get(v, v)
        for i, (x, y) in enumerate(glints):
            lv = (t + i) % 6
            if lv in (0, 1) and f[y][x] is None:
                star(f, x, y, 3 if lv == 0 else 2)
            elif lv == 2:
                put(f, x, y, C["ice"])
        out.append((f, 260))
    return out


def moon_phase(age):
    """age in [0,1): 0 new, .25 first quarter (right lit), .5 full, .75 last."""
    out = []
    k = math.cos(2 * math.pi * age)
    stars = [(1, 2), (14, 1), (13, 14)]
    for t in range(6):
        f = blank()
        cx, cy, r = 7.5, 7.5, 5.6
        for y in range(S):
            for x in range(S):
                nx, ny = (x - cx) / r, (y - cy) / r
                if nx * nx + ny * ny > 1:
                    continue
                s = math.sqrt(max(0.0, 1 - ny * ny))
                lit = nx > k * s if age < 0.5 else nx < -k * s
                edge = nx * nx + ny * ny > (1 - 1.1 / r) ** 2
                put(f, x, y, (C["moon_edge"] if edge else C["moon"]) if lit else C["earthshine"])
        for i, (x, y) in enumerate(stars):
            star(f, x, y, (1, 2, 3, 2, 1, 0)[(t + i * 2) % 6])
        out.append((f, 350))
    return out


def sun_event(rise):
    """The sun climbing out of (or sinking into) the horizon."""
    out = []
    path = [3, 2, 1, 0, 0, 0, 1, 2] if rise else [0, 1, 2, 3, 3, 3, 2, 1]
    for t in range(8):
        f = blank()
        cy = 9.5 + path[t]
        for y in range(S):
            for x in range(S):
                if y <= 11:
                    d2 = (x - 7.5) ** 2 + (y - cy) ** 2
                    if d2 <= 4.2 ** 2:
                        put(f, x, y, C["sun_edge"] if d2 > 3.1 ** 2 else C["sun"])
        for x in range(S):
            put(f, x, 12, C["horizon"])
        arrow_rows = [".#.", "###"] if rise else ["###", ".#."]
        sprite(f, arrow_rows, 6, 14, C["ray"])
        put(f, 7, 13 if rise else 15, C["ray_dim"])
        out.append((f, 260))
    return out


UMBRELLA = ["......##......",
            "....######....",
            "..##########..",
            ".############.",
            "##############",
            "#..#..#..#..#."]


def umbrella():
    out = []
    for t in range(6):
        f = blank()
        sprite(f, UMBRELLA, 1, 3, C["umbrella"])
        sprite(f, [UMBRELLA[4]], 1, 7, C["umbrella_dk"])
        for y in range(8, 14):
            put(f, 7, y, C["handle"])
        put(f, 6, 14, C["handle"]); put(f, 5, 13, C["handle"])
        for col, off in ((2, 0), (12, 2), (4, 1)):
            y = (t + off) % 3
            put(f, col, y, C["drop"])
        out.append((f, 180))
    return out


def uv_icon():
    out = []
    for t in range(4):
        f = blank()
        sun(f, 7.5, 7.5, 3.9, t, ray_len=2)
        # violet rays: the part of sunlight you cannot see
        for y in range(S):
            for x in range(S):
                if f[y][x] in (C["ray"], C["ray_dim"]):
                    f[y][x] = C["uv"] if f[y][x] == C["ray"] else C["uv_dim"]
        out.append((f, 300))
    return out


THEMES.update({
    "mainlyClearDay": lambda: mainly_clear(False), "mainlyClearNight": lambda: mainly_clear(True),
    "showersDay": lambda: showers(False), "showersNight": lambda: showers(True),
    "heavyRain": heavy_rain, "sleet": sleet, "freezingRain": freezing_rain,
    "snowShowersDay": lambda: showers(False, True), "snowShowersNight": lambda: showers(True, True),
    "hail": hail, "rimeFog": rime_fog,
})
DERIVED = {
    "windyDay": lambda: windy("day"), "windyNight": lambda: windy("night"),
    "cloudWindy": lambda: windy("cloud"), "blizzard": blizzard,
    "hot": hot, "frostyClear": frosty_clear,
}
MOON = {"moon%d" % i: (lambda a: (lambda: moon_phase(a)))(i / 8) for i in range(8)}
PAGE_ICONS.update({"sunrise": lambda: sun_event(True), "sunset": lambda: sun_event(False),
                   "umbrella": umbrella, "uv": uv_icon})
