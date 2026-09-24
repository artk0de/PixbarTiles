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
MARQUEE_STEP_MS = 60     # one pixel per frame, the whole pass at one speed
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
    "h": ["#..", "#..", "##.", "#.#", "#.#"],
    "k": ["#..", "#.#", "##.", "#.#", "#.#"],
    "s": [".##", "#..", ".#.", "..#", "##."],
    "t": [".#.", "###", ".#.", ".#.", ".##"],
}


# The kit's `PixelFont.big` — 5x9 digits, the same bytes `weather/wgen.py`
# draws its temperature with. Copied rather than imported: this file is meant
# to be copied out on its own, and a mockup that only renders next to the
# weather generator is a mockup nobody runs.
B = {
    "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "3": [".###.", "#...#", "....#", "....#", "..##.", "....#", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#..#.", "#####", "...#.", "...#.", "...#."],
    "5": ["#####", "#....", "#....", "####.", "....#", "....#", "....#", "#...#", ".###."],
    "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "....#", "...#.", "..#..", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", "#...#", ".###.", "#...#", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", "#...#", ".####", "....#", "....#", "....#", ".###."],
    "-": ["...", "...", "...", "...", "###", "...", "...", "...", "..."],
    "%": ["##..#", "##..#", "...#.", "...#.", "..#..", ".#...", ".#...", "#..##", "#..##"],
}


def text_width(s, font=G):
    return sum(len(font[ch][0]) + 1 for ch in s) - 1 if s else 0


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

    def text(self, s, x, y, c, clip=(0, W), font=G):
        for ch in s:
            self.bitmap(font[ch], x, y, c, clip)
            x += len(font[ch][0]) + 1


# Layout: logo 8x5 at (0,1); rows at y=1 and y=9 (text 5 rows, gap, 1px bar).
#
# The rows are named for the PERIOD they measure rather than with one letter
# each. "s" and "w" were one glyph because the face was built before there was
# anything else to call them, and a single letter is a legend the panel never
# prints: "5h" and "week" say what the row is about without one.
ROWS = (("5h", 1), ("week", 9))
# The mark is five rows tall and stands on the TOP row alone, so the top label
# starts after it and the bottom one starts at the panel's edge. Nine columns
# of the weekly row were being held for a mark that is not there, and they are
# exactly the columns its long reset was scrolling for.
LABEL_X = (9, 0)
LABEL_GAP = 4


def label_x(index):
    return LABEL_X[index]


def value_area(index):
    """Columns a row's value may use: after its OWN label, plus the gap.

    Per row rather than one box as wide as the widest name. That box was
    written for one-letter labels, where it kept the two marks from hanging off
    one another; with two words of different lengths it only takes the shorter
    row's columns away and gives nothing back.
    """
    label, _ = ROWS[index]
    return LABEL_X[index] + text_width(label) + LABEL_GAP, W


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
    for index, ((label, top), pct, (value, x)) in enumerate(zip(ROWS, pcts, values)):
        cv.text(label, label_x(index), top, LABEL)
        ink = value_ink(v, pct, dim)
        cv.text(value, W - text_width(value) if x is None else x, top, ink, value_area(index))
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


def reset_value(index, message):
    """A reset that fits, centred in the columns its row has left.

    Centred rather than right-aligned: for those seconds the reset is the whole
    content of the row, and inheriting the figure's alignment leaves a gap
    exactly where the eye starts reading.
    """
    lo, hi = value_area(index)
    return message, lo + (hi - lo - text_width(message)) // 2


def marquee_frames(vendor, pcts, values, index, message):
    """A reset too wide for its row: one full pass, a pixel a frame.

    It enters past the RIGHT EDGE OF THE PANEL and runs out past its row's left
    boundary. Starting at the row's left edge instead — which the first design
    did, to save frames — makes the line appear in the middle of the panel
    already half read, and that reads as a cut rather than as motion.

    The phase lasts as long as the pass takes, rather than the pass being
    decimated to fit a phase. Dropping positions to hit a fixed duration is
    exactly what makes a marquee stutter, and the panel has frames to spare: a
    full pass of the longest reset is under a hundred of the 478 it will play.
    """
    lo, _ = value_area(index)
    frames = []
    for x in range(W, lo - text_width(message) - 1, -1):
        shown = list(values)
        shown[index] = (message, x)
        frames.append((draw(vendor, pcts, shown), MARQUEE_STEP_MS))
    return frames


def timeline(vendor, s, w, interval_ms=DWELL_MS, step=1, marquee="edge", threshold=80):
    """[(canvas, ms)] — phase A percents; phase B the resets of the hot rows.

    A reset that fits its row stands still and centred; one that does not makes
    a single pass from off the right edge. `5h`'s `rst HH:mm` always fits;
    `week`'s `rst d mmm HH:mm` never does.
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
    messages = [f"rst {r['rst']}" for r in (s, w)]
    fits = [text_width(m) <= value_area(i)[1] - value_area(i)[0] for i, m in enumerate(messages)]
    # Everything that fits is placed first, so a row that has to scroll scrolls
    # with the other row's reset already standing beside it.
    values = [reset_value(i, messages[i]) if hot[i] and fits[i] else a[i] for i in range(2)]
    scrolling = [i for i in range(2) if hot[i] and not fits[i]]
    if not scrolling:
        frames.append((draw(vendor, pcts, values), DWELL_MS))
        return frames
    for index in scrolling:
        frames += marquee_frames(vendor, pcts, values, index, messages[index])
    return frames


# ── Circle: one window at a time, the reading drawn around the panel ──────
#
# Compact answers "where do both windows stand" in one glance and pays for it
# in size: two rows of 5x5 on a panel sixteen pixels tall leaves the figure the
# same height as its label. Circle answers "where does THIS window stand" and
# spends the whole panel on it — the reading at 5x9, and the bar unrolled
# around the edge, where it is 132 cells instead of 52 and one cell is under a
# percent.
#
# The rim is a frame, not a fourth row: it costs no interior pixels, and a
# reader who is not looking for it sees a panel with a coloured border rather
# than a chart they have to decode.
MARK_AT = (2, 2)
NAME_Y = 9
FIGURE_TOP = 3
FIGURE_RIGHT = W - 3
RESET_TOP = 4
# The mark occupies the top-left corner, so everything the rim frames starts
# after it. Eleven columns: the 8-wide mark at x2, and a column of air.
RESET_LEFT = 11
# What the dwell spends on the reset once a window is hot. The reading is the
# headline and keeps the larger share of every turn.
RESET_SHARE = 0.4
SWEEP_MS = 45
SWEEP_STEPS = 12


def rim_path():
    """The perimeter, clockwise from the top-left, each cell exactly once.

    Clockwise from (0,0) rather than from the bottom, because a gauge is read
    the way a clock is and the panel has no other zero to start from. The
    corners belong to the run that reaches them first, so no cell is drawn —
    or counted — twice.
    """
    top = [(x, 0) for x in range(W)]
    right = [(W - 1, y) for y in range(1, H)]
    bottom = [(x, H - 1) for x in range(W - 2, -1, -1)]
    left = [(0, y) for y in range(H - 2, 0, -1)]
    return top + right + bottom + left


RIM = rim_path()


def lit_cells(pct):
    """Cells of the rim a reading fills. A reading that exists is never zero
    cells: 1% has to look different from no data, and at 132 cells it rounds
    to one either way."""
    if pct is None or pct <= 0:
        return 0
    return max(1, round(len(RIM) * min(pct, 100) / 100))


def circle(vendor, name, pct, value=None, value_x=None, dim=False, lit=None):
    """One window: the rim at its reading, the mark in the corner, the name
    along the bottom, and either the figure or a reset inside.

    `lit` overrides what the reading would fill, and it is what makes the
    transition possible: during a change the rim shows a value between the two
    windows while the name and figure already belong to one of them.
    """
    v = VENDORS[vendor]
    cv = Canvas()
    colour = band_colour(pct, dim) if pct else TRACK
    lit = lit_cells(pct) if lit is None else lit
    for index, (x, y) in enumerate(RIM):
        cv.put(x, y, colour if index < lit else TRACK)
    cv.bitmap(v["logo"], *MARK_AT, v["logo_colour"])
    cv.text(name, 2, NAME_Y, LABEL, (2, W - 2))
    ink = value_ink(v, pct, dim)
    if value is None:
        figure = percent_text(pct)
        cv.text(figure, FIGURE_RIGHT - text_width(figure, B), FIGURE_TOP, ink,
                (RESET_LEFT, W - 2), B)
    else:
        cv.text(value, RESET_LEFT if value_x is None else value_x, RESET_TOP, ink,
                (RESET_LEFT, W - 2))
    return cv


def circle_reset_frames(vendor, name, pct, message, ms):
    """A reset inside the rim: still and centred when it fits, one pass from
    off the right edge when it does not — the same rule Compact's rows follow,
    over a wider area."""
    lo, hi = RESET_LEFT, W - 2
    width = text_width(message)
    if width <= hi - lo:
        return [(circle(vendor, name, pct, value=message,
                        value_x=lo + (hi - lo - width) // 2), ms)]
    return [(circle(vendor, name, pct, value=message, value_x=x), MARQUEE_STEP_MS)
            for x in range(W, lo - width - 1, -1)]


def circle_turn(vendor, name, pct, rst, dwell_ms, threshold):
    """One window's turn on the panel: its reading, then its reset if it has
    one and is past the threshold."""
    hot = pct is not None and bool(rst) and pct >= threshold
    reading_ms = int(dwell_ms * (1 - RESET_SHARE)) if hot else dwell_ms
    if pct is not None and pct >= 100:
        bright = circle(vendor, name, pct)
        dark = circle(vendor, name, pct, dim=True)
        beats = min(PULSE_FRAMES, max(2, reading_ms // PULSE_MS))
        frames = [(bright if i % 2 == 0 else dark, PULSE_MS) for i in range(beats)]
        rest = reading_ms - PULSE_MS * beats
        if rest > 0:
            frames.append((bright, rest))
    else:
        frames = [(circle(vendor, name, pct), reading_ms)]
    if hot:
        frames += circle_reset_frames(vendor, name, pct, f"rst {rst}", dwell_ms - reading_ms)
    return frames


def sweep_count(vendor, prev_pct, name, pct):
    """The change of window as one move: the rim runs from where it WAS to
    where it belongs while the figure counts with it.

    Counting is what makes this read as one instrument re-measuring rather
    than as two pages. A rim that slides under a figure that jumped is a rim
    catching up — the eye follows the digits, and the motion it was given
    happens somewhere it is not looking. The name changes on the first step,
    so from then on everything drawn is about the window being arrived at.

    A window with no reading has nothing to count to: it cuts, and the cut is
    honest — there is no value between 41% and "--".
    """
    if prev_pct is None or pct is None:
        return [(circle(vendor, name, pct), SWEEP_MS * 3)]
    a, b = min(prev_pct, 100), min(pct, 100)
    # Drawn AT the blended reading rather than with a blended rim under a
    # settled figure: one number drives the rim, the digits and the band
    # colour together, so the three cannot disagree for a frame.
    return [(circle(vendor, name, round(a + (b - a) * s / SWEEP_STEPS)), SWEEP_MS)
            for s in range(1, SWEEP_STEPS + 1)]


def circle_timeline(vendor, windows, dwell_ms=DWELL_MS, threshold=80):
    """[(canvas, ms)] — every selected window in turn, each arrived at by a count.

    `windows` is [(name, pct, rst)] in the order they are shown, and it is what
    the tile's multi-select produces: one window selected is one turn with no
    transition at all, because there is nothing to change to.
    """
    if len(windows) == 1:
        return circle_turn(vendor, *windows[0], dwell_ms, threshold)
    frames = []
    for index, (name, pct, rst) in enumerate(windows):
        frames += sweep_count(vendor, windows[index - 1][1], name, pct)
        frames += circle_turn(vendor, name, pct, rst, dwell_ms, threshold)
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
