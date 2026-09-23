#!/usr/bin/env python3
"""TC002 (52x16) usage-face mockups: Claude + Z.AI, one shared component.

Python is the only source of pixels: every case becomes a timeline of
(frame, duration_ms). index.html embeds that timeline and only plays it on a
canvas drawn as LED dots, so what the browser shows is exactly what was
computed. PNGs of key frames are written too, for a quick look without a
browser.
"""
import json, os, struct, zlib

W, H = 52, 16
OUT = os.environ.get("OUT") or os.path.join(os.getcwd(), "tc002-mockup-out")
os.makedirs(OUT, exist_ok=True)

DWELL_MS = 5000          # percent phase, and a reset that fits
SCROLL_STEP_MS = 60      # full marquee: one pixel per step
EDGE_STEP_MS = 100       # edge marquee: one pixel per step
EDGE_HOLD_START_MS = 1000
EDGE_HOLD_END_MS = 1500
TRACK = (0x30, 0x30, 0x30)
# The SPENT part of a bar — the progress itself — while the window is steady.
# Bright white, so what a glance lands on is how much of it is gone against the
# grey of what is left. White stands where a vendor's brand colour used to: the
# figure beside the bar already says which account this is, so the bar is free
# to spend its colour on how much is left.
PROGRESS = (0xFF, 0xFF, 0xFF)
LABEL = (0x60, 0x60, 0x60)


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# Past three quarters the fill takes the warning ramp instead — `UsageBand`'s
# thresholds and `UsageBand`'s colours, shared with the AWTRIX page, so a
# colour means the same thing wherever it shows. White alone left a bar at a
# third and a bar about to run out the same colour, differing only in length,
# which is the one reading a 52-pixel row is worst at. Five points a step, so
# the colour says HOW close rather than merely "close".
BANDS = (
    (100, hexrgb("#FF0000")),   # spent — the bucket is full
    (95, hexrgb("#FF3B30")),    # red
    (90, hexrgb("#FF6321")),    # orange leaning red
    (85, hexrgb("#FF8C1A")),    # orange
    (80, hexrgb("#FFAE3A")),    # light orange
    (75, hexrgb("#FFD24A")),    # yellow
)

# The other end of the spent pulse. A full bucket is the one state the ramp
# cannot shout any louder in colour: #FF3B30 already drives the red channel to
# 255 at 95%, and going brighter at that hue means adding white, which walks
# the red toward salmon. So past the cap the face spends MOTION instead of hue.
SPENT_DIM = hexrgb("#A00000")
PULSE_MS = 420
# It breathes this many frames and then holds. A pulse that never stops stops
# being read — the same reason the ramp starts as late as it does — and a long
# "show reset every" would otherwise spend the panel's whole frame budget on
# one blinking row.
PULSE_FRAMES = 24


def band_colour(pct, dim=False):
    if dim and pct >= 100:
        return SPENT_DIM
    for threshold, colour in BANDS:
        if pct >= threshold:
            return colour
    return PROGRESS


VENDORS = {
    "claude": {"name": "Claude", "brand": hexrgb("#D97757"), "logo_colour": hexrgb("#D97757"),
               "logo": [".######.",
                        ".#.##.#.",
                        "########",
                        ".######.",
                        ".##..##."]},
    "zai": {"name": "Z.AI", "brand": hexrgb("#3B5BFE"), "logo_colour": hexrgb("#E8E8E8"),
            "logo": ["#######",
                     "....##.",
                     "..###..",
                     ".##....",
                     "#######"]},
}

# 3x5 glyphs (w is 5 wide, ':' '.' ' ' are 1 wide), rows top-first, '#' lit.
G = {
    "0": ["###", "#.#", "#.#", "#.#", "###"],
    "1": ["##.", ".#.", ".#.", ".#.", "###"],
    "2": ["###", "..#", "###", "#..", "###"],
    "3": ["###", "..#", "###", "..#", "###"],
    "4": ["#.#", "#.#", "###", "..#", "..#"],
    "5": ["###", "#..", "###", "..#", "###"],
    "6": ["###", "#..", "###", "#.#", "###"],
    "7": ["###", "..#", "..#", "..#", "..#"],
    "8": ["###", "#.#", "###", "#.#", "###"],
    "9": ["###", "#.#", "###", "..#", "###"],
    "%": ["#..", "..#", ".#.", "#..", "..#"],
    "-": ["...", "...", "###", "...", "..."],
    ":": [".", "#", ".", "#", "."],
    ".": [".", ".", ".", ".", "#"],
    " ": [".", ".", ".", ".", "."],
    "a": ["##.", "..#", ".##", "#.#", ".##"],
    "b": ["#..", "#..", "##.", "#.#", "##."],
    "c": [".##", "#..", "#..", "#..", ".##"],
    "d": ["..#", "..#", ".##", "#.#", ".##"],
    "e": [".#.", "#.#", "###", "#..", ".##"],
    "f": [".##", "#..", "###", "#..", "#.."],
    "g": [".##", "#.#", ".##", "..#", "##."],
    "j": ["..#", "...", "..#", "#.#", ".#."],
    "l": ["#..", "#..", "#..", "#..", ".##"],
    "m": ["##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"],
    "n": ["##.", "#.#", "#.#", "#.#", "#.#"],
    "o": [".#.", "#.#", "#.#", "#.#", ".#."],
    "p": ["##.", "#.#", "##.", "#..", "#.."],
    "u": ["#.#", "#.#", "#.#", "#.#", ".##"],
    "v": ["#.#", "#.#", "#.#", "#.#", ".#."],
    "y": ["#.#", "#.#", ".##", "..#", "##."],
    "r": [".##", "#..", "#..", "#..", "#.."],
    "w": ["#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
    "s": [".##", "#..", ".#.", "..#", "##."],
    "t": [".#.", "###", ".#.", ".#.", ".##"],
}


def text_width(s):
    return sum(len(G[ch][0]) + 1 for ch in s) - 1 if s else 0


class Canvas:
    def __init__(self):
        self.px = [[None] * W for _ in range(H)]

    def put(self, x, y, c, clip=(0, W)):
        if clip[0] <= x < clip[1] and 0 <= y < H:
            self.px[y][x] = c

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.put(xx, yy, c)

    def bitmap(self, rows, x, y, c, clip=(0, W)):
        for dy, row in enumerate(rows):
            for dx, ch in enumerate(row):
                if ch == "#":
                    self.put(x + dx, y + dy, c, clip)

    def text(self, s, x, y, c, clip=(0, W)):
        for ch in s:
            self.bitmap(G[ch], x, y, c, clip)
            x += len(G[ch][0]) + 1


# Layout: logo 8x5 at (0,1); rows at y=1 and y=9 (text 5 rows, gap, 1px bar).
TEXT_X = 9
ROWS = (("s", 1), ("w", 9))
# The labels are centred on each other rather than flush left. In the
# proportional face "s" is three columns wide and "w" is five, so left-aligned
# they hang off one another by two pixels — one row's mark visibly left of the
# other's on a panel where the two rows are read as a pair.
LABEL_BOX = max(len(G[label][0]) for label, _ in ROWS)


def label_x(label):
    return TEXT_X + (LABEL_BOX - len(G[label][0])) // 2


def value_area(label):
    """Columns right of the label a value may use: label, 4px gap, to the edge."""
    return TEXT_X + text_width(label) + 4, W


def value_ink(v, pct, dim=False):
    """The figure's colour: the vendor's MARK while the window is steady, the
    bar's own warning colour once it is not.

    While nothing is near a limit the figure is identity — WHICH account this
    is — and the bar alone carries how much is left. Past four fifths that
    stops being the useful split: the figure and the bar under it are one
    statement, and a warm figure over a warm bar is the thing the eye lands on
    first. (z.ai's mark is near-white while its brand is blue, which is why
    this reads the mark and never the brand.)
    """
    if pct is None:
        return TRACK
    colour = band_colour(pct, dim)
    return v["logo_colour"] if colour == PROGRESS else colour


def draw(vendor, pcts, values, dim=False):
    """pcts: [pct|None]*2; values: per row (text, x) — x None = right-aligned.

    `dim` is the low half of the spent pulse; it moves nothing but the colour
    of a row whose bucket is full.
    """
    v = VENDORS[vendor]
    cv = Canvas()
    cv.bitmap(v["logo"], 0, 1, v["logo_colour"])
    for (label, top), pct, (value, x) in zip(ROWS, pcts, values):
        cv.text(label, label_x(label), top, LABEL)
        ink = value_ink(v, pct, dim)
        cv.text(value, W - text_width(value) if x is None else x, top, ink, value_area(label))
        bar_y = top + 6
        cv.rect(0, bar_y, W, 1, TRACK)
        if pct:
            cv.rect(0, bar_y, max(1, round(W * min(pct, 100) / 100)), 1, band_colour(pct, dim))
    return cv


def percent_phase(vendor, pcts, values, interval_ms):
    """Frame A: one still frame, or the spent pulse when a bucket is full.

    The pulse is the percent phase's alone. A row showing its reset is being
    read as TEXT — the session's still, the week's gliding a pixel a frame —
    and text that blinks under the eye is text nobody finishes.
    """
    if not any(p is not None and p >= 100 for p in pcts):
        return [(draw(vendor, pcts, values), interval_ms)]
    bright, dark = draw(vendor, pcts, values), draw(vendor, pcts, values, dim=True)
    # Floor, so the beats plus the rest come to exactly the interval asked for
    # rather than overrunning it by part of a beat.
    beats = min(PULSE_FRAMES, max(2, interval_ms // PULSE_MS))
    frames = [(bright if i % 2 == 0 else dark, PULSE_MS) for i in range(beats)]
    rest = interval_ms - PULSE_MS * beats
    if rest > 0:
        frames.append((bright, rest))
    return frames


def percent_text(pct):
    return "--" if pct is None else f"{min(pct, 100)}%"


def timeline(vendor, s, w, interval_ms=DWELL_MS, step=1, marquee="edge", threshold=80):
    """[(canvas, ms)] — phase A percents; phase B resets for rows >= 80%.

    s reset: 'rst HH:mm' (fits, static). w reset: 'rst dd.MM HH:mm' as a
    marquee through its value area, entering at the right edge and leaving at
    the left; phase B lasts as long as the marquee does.
    """
    pcts = [s["pct"], w["pct"]]
    # Hot needs BOTH a reading past the threshold and a reset the source named.
    # A row that has nothing to flip to keeps its percentage rather than
    # flipping to the word "rst" with nothing after it.
    hot = [p is not None and p >= threshold and bool(r["rst"])
           for p, r in zip(pcts, (s, w))]
    a = [(percent_text(p), None) for p in pcts]
    frames = percent_phase(vendor, pcts, a, interval_ms)
    if not any(hot):
        return frames
    s_val = (f"rst {s['rst']}", None) if hot[0] else a[0]
    if not hot[1]:
        frames.append((draw(vendor, pcts, [s_val, a[1]]), DWELL_MS))
        return frames
    msg = f"rst {w['rst']}"
    lo, hi = value_area("w")
    if marquee == "full":
        for x in range(hi, lo - text_width(msg) - 1, -step):
            frames.append((draw(vendor, pcts, [s_val, (msg, x)]), SCROLL_STEP_MS * step))
        return frames
    # "edge": start readable at the zone's left edge, glide 1px at a time until
    # the tail shows, hold both ends — smooth 1px motion inside ~25 frames.
    end = min(lo, hi - text_width(msg))
    xs = list(range(lo, end - 1, -step))
    if xs[-1] != end:
        xs.append(end)
    for i, x in enumerate(xs):
        ms = EDGE_HOLD_START_MS if i == 0 else EDGE_HOLD_END_MS if i == len(xs) - 1 else EDGE_STEP_MS * step
        frames.append((draw(vendor, pcts, [s_val, (msg, x)]), ms))
    return frames


def png(cv, path, cell=14, dot=11):
    bg, off = (0x0A, 0x0A, 0x0A), (0x16, 0x16, 0x16)
    pad, r = cell, dot / 2
    iw, ih = W * cell + 2 * pad, H * cell + 2 * pad
    rows = []
    for y in range(ih):
        row = bytearray([0])
        for x in range(iw):
            gx, gy = (x - pad) // cell, (y - pad) // cell
            c = bg
            if 0 <= gx < W and 0 <= gy < H:
                cx = (x - pad) - gx * cell - cell / 2 + 0.5
                cy = (y - pad) - gy * cell - cell / 2 + 0.5
                if abs(cx) <= r and abs(cy) <= r and not (abs(cx) > r - 2 and abs(cy) > r - 2):
                    c = cv.px[gy][gx] or off
            row += bytes(c)
        rows.append(bytes(row))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", iw, ih, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(b"".join(rows), 9)))
        f.write(chunk(b"IEND", b""))


def R(pct, rst=""):
    return {"pct": pct, "rst": rst}


CASES = [
    ("01-steady", "Обе полосы < 80% — только проценты, цвет вендора",
     R(23), R(41)),
    ("02-s-watch", "s 84% (watch) → раз в 5 с «rst 14:30» (время, локальная TZ), статично",
     R(84, "14:30"), R(52)),
    ("03-w-close", "w 92% (close) → бегущая строка «rst 26 sep 15:00» (дата+время, локальная TZ)",
     R(35), R(92, "26 sep 15:00")),
    ("03b-tz", "Таймзона: сервер z.ai живёт в Asia/Shanghai (сброс 26.09 21:00 CST) — на панели локальное MSK: «rst 26 sep 16:00»",
     R(40), R(90, "26 sep 16:00")),
    ("04-both-hot", "s 97% (spent) + w 88% (watch): s — время статично, w — бегущей строкой",
     R(97, "09:05"), R(88, "1 oct 09:00")),
    ("05-spent-cap", "Лимит выбран: 100% (и >100% тоже рисуется как 100%)",
     R(104, "23:59"), R(100, "30 sep 23:59")),
    ("06-zero", "0% — пустой трек; 3% — минимум 1 пиксель заливки",
     R(0), R(3)),
    ("07-no-data", "Нет данных — «--» цветом трека, пустые полосы",
     R(None), R(None)),
    ("08-partial", "Частичные данные: session есть, weekly нет",
     R(12), R(None)),
    ("09-threshold", "Порог Show reset after: s 72%, w 61% — при 80% сброса нет, при 70% мигает s, при 60% — обе строки",
     R(72, "18:10"), R(61, "28 sep 16:00")),
]


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


THRESHOLDS = list(range(50, 101, 5))


def main():
    palette, cases = {}, []
    for cid, desc, s, w in CASES:
        entry = {"id": cid, "desc": desc, "vendors": []}
        for vendor in VENDORS:
            by_thr = {}
            for thr in THRESHOLDS:
                tl = timeline(vendor, s, w, threshold=thr)
                keys = [0, 1, (len(tl) + 1) // 2][:min(len(tl), 3)]
                if thr == 80:
                    for n, k in enumerate(keys):
                        png(tl[k][0], os.path.join(OUT, f"{vendor}-{cid}-{n}.png"))
                by_thr[thr] = {"frames": [{"px": encode(cv, palette), "ms": ms} for cv, ms in tl],
                               "keys": keys}
            entry["vendors"].append({"name": VENDORS[vendor]["name"], "byThreshold": by_thr})
        cases.append(entry)
    pal = ["#%02x%02x%02x" % c for c, _ in sorted(palette.items(), key=lambda kv: kv[1])]
    data = json.dumps({"W": W, "H": H, "palette": pal, "thresholds": THRESHOLDS, "cases": cases},
                      ensure_ascii=False, separators=(",", ":"))
    tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "template.html")).read()
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(tpl.replace("/*DATA*/null", data))
    print(len(cases), "cases,", len(data) // 1024, "KB of frames")


if __name__ == "__main__":
    main()
