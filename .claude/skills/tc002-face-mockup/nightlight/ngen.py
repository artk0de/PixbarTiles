#!/usr/bin/env python3
"""Night light tile — the six TC002 scenes (52×16), the pixel oracle for the
Swift face (`Sources/PixbarKit/NightLight/`).

Embers, Warm horizon and Red moon start from the user's mock sheet
(`mock-sheet.png`), traced into intensity maps (`maps.py`, by `make_maps.py`);
Fireflies, Fireplace and Soft glow are drawn procedurally across the whole
width. Animation layers run on top of either.

Integer arithmetic only, so Swift can reproduce every pixel: a 32-bit LCG for
every random choice, the 256-entry `SIN` table for every oscillation, `sdiv`
(truncation toward zero, Swift's `/`) wherever a signed value is divided.

Every motion runs a whole number of cycles over the loop's N frames, so frame
N is frame 0 and the GIF loops without a seam.

  python3 ngen.py            # renders out/index.html and key-frame PNGs
"""
import base64, json, math, os, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]
import gen          # noqa: E402  Canvas, encode
import maps         # noqa: E402  the traced sheet
import redmoon      # noqa: E402  the first engine-driven theme
import embers as ember_scene  # noqa: E402
import fireflies as firefly_scene  # noqa: E402
import horizon as horizon_scene  # noqa: E402
import fireplace as fireplace_scene  # noqa: E402
import glow as glow_scene  # noqa: E402
import tc002_demo   # noqa: E402  the GIF writer

OUT = os.path.join(HERE, "out")
W, H = 52, 16
N = 120                 # frames per loop
FRAME_MS = 100          # 10 cs — a whole number of centiseconds
GIF_B64_LIMIT = 136_000
FRAME_LIMIT = 480

# ── the warm palette, darkest first; black below the first stop ──
PALETTE = ["#4A0A0A", "#8C0F14", "#D2321E", "#E8640F", "#F0A040"]
STOPS = [0, 48, 96, 150, 205, 255]          # intensity where each colour sits
CUT = 20                                    # below this a dot is off
LEVELS = [1, 2, 3, 4, 5]                    # brightness steps: 20 … 100 %


def hexrgb(h):
    return (int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16))


RAMP_COLOURS = [(0, 0, 0)] + [hexrgb(h) for h in PALETTE]

# round(127·sin(2πi/256)); a literal on the Swift side, pinned by the fixture.
SIN = [int(round(127 * math.sin(2 * math.pi * i / 256))) for i in range(256)]


class LCG:
    """Numerical Recipes' 32-bit LCG; `next(n)` is the high bits mod n."""

    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF

    def next(self, n):
        self.s = (self.s * 1664525 + 1013904223) & 0xFFFFFFFF
        return (self.s >> 16) % n


def sdiv(a, b):
    """Division truncating toward zero — Swift's `/` — for signed operands."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def osc(frame, cycles, phase=0):
    """SIN at `cycles` whole turns per loop (cycles ≥ 0), −127…127."""
    return SIN[(frame * cycles * 256 // N + phase) & 255]


def wave(frame, cycles, phase):
    """SIN travelling the other way: the phase falls as the loop runs."""
    return SIN[(phase - frame * cycles * 256 // N) & 255]


def ramp(v):
    """Intensity 0…255 → a warm colour, or None when the dot is off."""
    if v < CUT:
        return None
    v = min(v, 255)
    for i in range(len(STOPS) - 1):
        a, b = STOPS[i], STOPS[i + 1]
        if v <= b:
            ca, cb = RAMP_COLOURS[i], RAMP_COLOURS[i + 1]
            span = b - a
            return tuple((ca[k] * (b - v) + cb[k] * (v - a) + span // 2) // span for k in range(3))
    return RAMP_COLOURS[-1]


AMBER = hexrgb("#F0A040")


def amber(v):
    """Intensity → the amber core dimmed, for the fireflies: a dim firefly is
    brown-amber, not red."""
    if v < CUT:
        return None
    v = min(v, 255)
    return tuple((ch * v + 127) // 255 for ch in AMBER)


def scaled(c, level):
    """A colour at brightness step `level` (1…5), or None when it goes dark."""
    if c is None:
        return None
    out = tuple((ch * level + 2) // 5 for ch in c)
    return out if any(out) else None


def clamp(v):
    return 0 if v < 0 else 255 if v > 255 else v


def blank():
    return [[0] * W for _ in range(H)]


def traced(name):
    return [[int(row[2 * x:2 * x + 2], 16) for x in range(W)] for row in maps.MAPS[name]]


def spark(g, f, x, bottom, rise, cycles, off, peak, drift=0):
    """One spark rising `rise` rows from `bottom` and fading, `cycles` times a
    loop; `drift` columns sideways over the rise. A dim dot trails below it."""
    period = N // cycles
    t = (f * cycles + off) % N * period // N        # 0 … period-1, periodic in N
    y = bottom - t * rise // period
    xx = (x + sdiv(drift * t, period)) % W
    v = clamp(peak - t * (peak - 30) // period)
    if 0 <= y < H:
        g[y][xx] = max(g[y][xx], v)
    if 0 <= y + 1 < H and t > 0:
        g[y + 1][xx] = max(g[y + 1][xx], v // 3)


# ── scenes: frame → 52×16 grid of intensities ──

def ember_bed():
    """The sheet's bed, its lower seven rows stretched to ten: the fire is
    three rows taller than the sheet, as asked."""
    m = traced("embers")
    bed = blank()
    for ty in range(6, H):
        sy = H - 1 - (H - 1 - ty) * 7 // 10
        for x in range(W):
            bed[ty][x] = m[sy][x] if sy >= 9 else 0
    return bed


def embers(f):
    bed = ember_bed()
    g = blank()
    r = LCG(0x0E3B)
    for y in range(H):
        for x in range(W):
            b = bed[y][x]
            k, ph = 1 + r.next(3), r.next(256)
            if b:
                amp = b * 40 // 100 + 12
                v = b + sdiv(amp * osc(f, k, ph), 127) + sdiv(18 * wave(f, 2, x * 6 + y * 11), 127)
                g[y][x] = clamp(v)
    for _ in range(24):
        x = r.next(W)
        spark(g, f, x, 8 + r.next(4), 5 + r.next(6), 2 + r.next(4), r.next(N), 170 + r.next(80), r.next(3) - 1)
    return g


def horizon(f):
    m = traced("horizon")
    g = blank()
    r = LCG(0x40A1)
    gain = 100 + sdiv(22 * osc(f, 2), 127)                 # the whole band breathes
    cx2 = 52 + sdiv(44 * osc(f, 1), 127)                   # doubled x of the hot spot, edge to edge
    for x in range(W):
        lift = sdiv(2 * wave(f, 3, x * 14), 127) + sdiv(osc(f, 1, x * 5), 127)
        for y in range(H):
            sy = y + lift
            b = m[sy][x] if 0 <= sy < H else (m[H - 1][x] if sy >= H else 0)
            k, ph = 1 + r.next(3), r.next(256)
            if not b:
                continue
            spot = 150 - abs(2 * x - cx2) * 5
            v = b * gain // 100 + (spot * b // 255 if spot > 0 else 0)
            v += sdiv(16 * osc(f, k, ph), 127)
            g[y][x] = clamp(v)
    for _ in range(16):                                    # heat haze rising off the band
        spark(g, f, r.next(W), 11, 4 + r.next(4), 1 + r.next(3), r.next(N), 60 + r.next(40))
    return g


def fireflies(f):
    g = blank()
    r = LCG(0xF1F1)
    for i in range(26):
        big = i < 8
        cx2, cy2 = 2 + r.next(100), 2 + r.next(28)         # doubled centre
        ax, ay = 4 + r.next(12), 2 + r.next(5)
        kx, ky, kp = 1 + r.next(2), 1 + r.next(3), 1 + r.next(3)
        px, py, pp = r.next(256), r.next(256), r.next(256)
        x = sdiv(cx2 + sdiv(ax * osc(f, kx, px), 127), 2)
        y = sdiv(cy2 + sdiv(ay * osc(f, ky, py), 127), 2)
        if big:
            glow = 160 + sdiv(95 * osc(f, kp, pp), 127)    # 65 … 255
            dots = ((0, 0, 100), (1, 0, 32), (-1, 0, 32), (0, 1, 32), (0, -1, 32),
                    (1, 1, 14), (-1, 1, 14), (1, -1, 14), (-1, -1, 14))
        else:
            glow = 85 + sdiv(65 * osc(f, kp, pp), 127)     # 20 … 150
            dots = ((0, 0, 100),)
        for dx, dy, share in dots:
            xx, yy = x + dx, y + dy
            if 0 <= xx < W and 0 <= yy < H:
                g[yy][xx] = max(g[yy][xx], glow * share // 100)
    return g


FIRE_NOISE_ROWS = 32


def fire_noise():
    r = LCG(0xF12E)
    return [[r.next(256) for _ in range(W)] for _ in range(FIRE_NOISE_ROWS)]


def fireplace(f):
    g = blank()
    noise = fire_noise()
    r = LCG(0xF1AE)
    rise = f * FIRE_NOISE_ROWS * 3 // N                    # the texture climbs 3 heights a loop
    tongues = []
    for i in range(10):
        cx = 2 + i * 5 + r.next(3)
        centre = 12 - abs(2 * cx - 51) * 6 // 51           # the tallest in the middle
        tongues.append((cx, centre, 2 + r.next(3), 2 + r.next(3), r.next(256), 3 + r.next(3)))
    heights = []
    for x in range(W):
        top = 3 + sdiv(osc(f, 2, x * 29), 127)             # a low flame the whole width
        for cx, centre, amp, k, ph, half in tongues:
            h = centre + sdiv(amp * osc(f, k, ph), 127)
            top = max(top, h - abs(x - cx) * h // half)
        heights.append(min(H, top))
    for x in range(W):
        h = max(2, heights[x])
        for d in range(h):
            y = H - 1 - d
            n = noise[(y + rise) % FIRE_NOISE_ROWS][x]
            v = 250 - d * 230 // h - abs(2 * x - 51) * 70 // 51
            v = v * (100 + sdiv((n - 128) * 50, 128)) // 100
            if n < 40 and d > 1:
                v //= 4                                    # a gap in the flame
            g[y][x] = clamp(v)
    for x in range(W):                                     # the bed, glowing
        g[H - 1][x] = max(g[H - 1][x], clamp(100 + sdiv(40 * osc(f, 2, x * 23), 127)))
    for _ in range(14):                                    # sparks above the tongues
        x = r.next(W)
        spark(g, f, x, H - 1 - heights[x], 3 + r.next(5), 3 + r.next(3), r.next(N), 140 + r.next(90), r.next(3) - 1)
    return g


def glow(f):
    g = blank()
    r = LCG(0x6E0B)
    reach = 58 + sdiv(4 * osc(f, 1), 127)                  # the breathing radius
    for y in range(H):
        for x in range(W):
            dx, dy = W - 1 - x, (H - 1 - y) * 3
            d = math.isqrt(dx * dx + dy * dy)
            k, ph, hole = 2 + r.next(3), r.next(256), r.next(100)
            if d >= reach:
                continue
            v = 255 * (reach - d) // reach
            v += sdiv(22 * wave(f, 2, x * 5 + y * 9), 127) if v > 40 else 0
            if v < 60:                                     # the fringe breaks up and sparkles
                if hole < 45:
                    continue
                v = v * (128 + osc(f, k, ph)) // 180
            g[y][x] = clamp(v)
    return g


SCENES = [
    ("embers", "Тлеющие угли", None),        # engine-driven: embers.scene()
    ("horizon", "Тёплый горизонт", None),     # engine-driven: horizon.scene()
    ("moon", "Красный месяц", None),        # engine-driven: redmoon.scene()
    ("fireflies", "Светлячки", None),        # engine-driven: fireflies.scene()
    ("fireplace", "Камин", None),            # engine-driven: fireplace.scene()
    ("glow", "Мягкое свечение", None),       # engine-driven: glow.scene()
]


ENGINE = {"moon": redmoon.scene(), "embers": ember_scene.scene(), "fireflies": firefly_scene.scene(),
          "horizon": horizon_scene.scene(), "fireplace": fireplace_scene.scene(), "glow": glow_scene.scene()}
SPEEDS = [(1, 2), (1, 1), (2, 1)]
def toggles(sid):
    """The motion settings of an engine scene: its layers' keys, in order."""
    return list(dict.fromkeys(l.key for l in ENGINE[sid].layers if l.key))


def timeline(scene, level, speed=(1, 1), off=frozenset()):
    """[(Canvas, ms)] for one scene at a brightness step; `speed` and `off`
    apply to engine-driven scenes only."""
    if scene in ENGINE:
        ps = ENGINE[scene]
        n = ps.frames(speed)
        frames = []
        for f in range(n):
            cv = gen.Canvas()
            grid = ps.render(f, n, off)
            for y in range(H):
                for x in range(W):
                    cv.px[y][x] = scaled(grid[y][x], level)
            frames.append((cv, ps.frame_ms))
        return frames
    fn = dict((sid, fn) for sid, _, fn in SCENES)[scene]
    colour = amber if scene == "fireflies" else ramp
    frames = []
    for f in range(N):
        cv = gen.Canvas()
        grid = fn(f)
        for y in range(H):
            for x in range(W):
                cv.px[y][x] = scaled(colour(grid[y][x]), level)
        frames.append((cv, FRAME_MS))
    return frames


def png(cv, path, cell=8):
    w, h = W * cell, H * cell
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            c = cv.px[y // cell][x // cell]
            inside = cell // 8 <= x % cell < cell - cell // 8 and cell // 8 <= y % cell < cell - cell // 8
            row += bytes(c if (c and inside) else (0x16, 0x16, 0x16) if inside else (0x0A, 0x0A, 0x0A))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


def lit_share(tl):
    """How much of the panel is lit, on average over the loop, in per cent."""
    lit = sum(1 for cv, _ in tl for row in cv.px for c in row if c)
    return lit * 100 // (len(tl) * W * H)


def variant(scene, palette, speed=(1, 1), off=frozenset(), keyframes=False):
    """One playable variant: frames at 100 % (the page scales them with the
    same integer step), and the GIF's base64 size at every brightness step."""
    sizes, top, colours = {}, None, 0
    for level in LEVELS:
        tl = timeline(scene, level, speed, off)
        cs = {c for cv, _ in tl for row in cv.px for c in row if c}
        assert len(cs) <= 255, f"{scene} L{level}: {len(cs)} colours"
        assert len(tl) <= FRAME_LIMIT, f"{scene}: {len(tl)} frames"
        sizes[level] = len(base64.b64encode(tc002_demo.gif(tl)))
        if level == 5:
            top, colours = tl, len(cs)
    if keyframes:
        for tag, i in (("a", 0), ("b", len(top) // 3)):
            png(top[i][0], os.path.join(OUT, f"{scene}-{tag}.png"))
    return {"frames": [{"px": gen.encode(cv, palette), "ms": ms} for cv, ms in top],
            "b64": sizes, "colours": colours, "lit": lit_share(top)}


# Where each scene's panel sits on mock-sheet.png: (left, top, right, bottom).
SHEET_BOXES = {
    "embers": (44, 163, 738, 337), "horizon": (798, 163, 1492, 337),
    "moon": (44, 408, 738, 581), "fireflies": (798, 408, 1492, 581),
    "fireplace": (44, 647, 738, 820), "glow": (798, 647, 1492, 820),
}


def sheet_crop(sid):
    """The scene's panel from the mock sheet as a PNG data URI, for the page to
    show beside the render."""
    import pickle
    import pngread
    cache = os.path.join(OUT, "sheet.pkl")
    if os.path.exists(cache):
        px = pickle.load(open(cache, "rb"))
    else:
        _, _, px = pngread.read(os.path.join(HERE, "mock-sheet.png"))
        pickle.dump(px, open(cache, "wb"))
    l, t, r, b = SHEET_BOXES[sid]
    rows = [bytes([0]) + b"".join(bytes(px[y][x]) for x in range(l, r)) for y in range(t, b)]

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    blob = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", r - l, b - t, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))
    return "data:image/png;base64," + base64.b64encode(blob).decode()


def main():
    os.makedirs(OUT, exist_ok=True)
    gen.W, gen.H = W, H
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    palette, scenes = {}, []
    for sid, name, _ in SCENES:
        if only and sid not in only:
            continue
        entry = {"id": sid, "name": name, "variants": {}, "sheet": sheet_crop(sid)}
        if sid in ENGINE:
            entry["engine"] = {"speeds": [f"{a}/{b}" for a, b in SPEEDS], "toggles": toggles(sid)}
            for sp in SPEEDS:
                for bits in range(1 << len(toggles(sid))):
                    off = frozenset(t for i, t in enumerate(toggles(sid)) if bits >> i & 1)
                    entry["variants"][f"{sp[0]}/{sp[1]}|{bits}"] = variant(
                        sid, palette, sp, off, keyframes=(sp == (1, 1) and bits == 0))
            entry["default"] = "1/1|0"
        else:
            entry["variants"]["default"] = variant(sid, palette, keyframes=True)
            entry["default"] = "default"
        d = entry["variants"][entry["default"]]
        worst = max(v["b64"][5] for v in entry["variants"].values())
        print(f"{sid:10} {len(d['frames']):3} frames, {d['colours']:3} colours, lit {d['lit']:2}%, "
              f"base64 at 100% {d['b64'][5]:6} B, worst variant {worst:6} B"
              + ("  OVER BUDGET" if worst > GIF_B64_LIMIT else ""))
        scenes.append(entry)
    pal = ["#%02x%02x%02x" % c for c, _ in sorted(palette.items(), key=lambda kv: kv[1])]
    data = json.dumps({"W": W, "H": H, "palette": pal, "limit": GIF_B64_LIMIT,
                       "swatches": PALETTE, "scenes": scenes}, ensure_ascii=False, separators=(",", ":"))
    tpl = open(os.path.join(HERE, "ntemplate.html")).read()
    with open(os.path.join(OUT, "index.html"), "w") as fh:
        fh.write(tpl.replace("/*DATA*/null", data))
    print("palette", len(palette), "→", os.path.join(OUT, "index.html"))


if __name__ == "__main__":
    main()
