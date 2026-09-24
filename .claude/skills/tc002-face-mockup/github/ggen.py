#!/usr/bin/env python3
"""TC002 (52x16) GitHub face — the pixel source of truth.

Two timelines, each ONE 52x16 GIF (tc002-ticker-motion: what must stay in step
lives in one GIF):

- ambient: the animated octocat, the star count as the hero figure (rows 0-8),
  and a ticker line (rows 11-15) rotating the repo's short name, forks and
  open PRs;
- celebration: what an interruption shows for M seconds — the event's icon
  popping in, `+N` as the hero, and a ticker naming who (stars go to every
  page the app owns, forks and new PRs to the GitHub page only; that routing
  is the session's, not this face's).

Glyphs, big digits, Area, play/compose and the GIF writer are wgen's — one
table per font across faces; GitHub's additions extend them here.

Run it to rebuild index.html and the key-frame PNGs from `CASES`.
"""
from __future__ import annotations

import json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "weather"))
import wgen  # noqa: E402
import sheet  # noqa: E402
sys.path.insert(0, HERE)
from octicons import OCTICONS  # noqa: E402
from wgen import W, H, AREA_X, AREA_W, LABEL, DIM, STEP_MS, SLIDE, Area, play, compose, fits, hexrows  # noqa: E402

hexrgb = wgen.hexrgb

# ---- glyphs: wgen's tables plus what repo names and logins need --------------
G = dict(wgen.G)
G.update({
    "j": ["..#", "...", "..#", "#.#", ".#."],
    "_": ["...", "...", "...", "...", "###"],
    "+": ["...", ".#.", "###", ".#.", "..."],
    "#": [".#.#.", "#####", ".#.#.", "#####", ".#.#."],
    # A person, before a login: `@` does not read at 5 px (two shapes tried on
    # the panel); this bust was picked there, in grey so it cannot be taken
    # for an event's own colour (2026-09-23).
    "☺": [".###.", ".###.", ".....", "#####", "#####"],
})

B = dict(wgen.B)
B.update({
    "+": [".....", ".....", "..#..", "..#..", "#####", "..#..", "..#..", ".....", "....."],
    "k": ["#....", "#....", "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "m": [".....", ".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#", "#.#.#"],
    "★": ["....#....", "....#....", "...###...", "#########", ".#######.", "..#####..",
          "..##.##..", ".##...##.", ".#.....#."],
    # The CI event's hero, lowercase at x-height like `m` (DRAFT, 2026-09-23).
    "c": [".....", ".....", ".....", ".###.", "#...#", "#....", "#....", "#...#", ".###."],
    "i": [".", "#", ".", "#", "#", "#", "#", "#", "#"],
    # Main watch (2026-09-24): the fork and the pull request as the hero's
    # mark when one of them holds the hero instead of the stars — the
    # octicons' shapes at the big digits' height and the star's width, their
    # commits as 3x3 rings (a filled block read as a digit's stroke): two tips
    # joining into a base; a branch beside a base with the arrow coming in.
    "⑂": ["###...###", "#.#...#.#", "###...###", ".#.....#.", "..#...#..", "...#.#...", "...###...",
          "...#.#...", "...###..."],
    "⎇": ["###..#...", "#.#.####.", "###..#.#.", ".#.....#.", ".#.....#.", ".#.....#.", "###...###",
          "#.#...#.#", "###...###"],
})


def width(s, font=G):
    return wgen.width(s, font)


# ---- colours (GitHub's own: star gold, fork blue, open-PR green) --------------
# Gold as the panel shows it: GitHub's #E3B341 read orange on the LEDs, whose
# red channel dominates; #FFD84A was picked on the clock (2026-09-23).
STAR = hexrgb("#FFD84A")
STAR_CORE = STAR
FORK = hexrgb("#58A6FF")
PR = hexrgb("#3FB950")
WHITE = hexrgb("#E8E8E8")
PERSON = hexrgb("#909090")
MARK = hexrgb("#B8B8B8")
SHINE = hexrgb("#FFFFFF")
# The default branch's CI: GitHub's own check colours. Success has none — the
# lamp is absent then (the user's call, 2026-09-23).
CI_FAIL = hexrgb("#F85149")
CI_PENDING = hexrgb("#D29922")

# ---- icons (16x16, [(grid, ms)] loops) ------------------------------------------


def blank():
    return [[None] * 16 for _ in range(16)]


FULL, EDGE = 0.6, 0.25          # coverage: >= FULL lit, >= EDGE a dimmed edge
EDGE_TINT = 0.45


def tint(c, k):
    return tuple(round(v * k) for v in c)


def coverage(key):
    return [[int(r[2 * x:2 * x + 2], 16) / 255 for x in range(16)] for r in OCTICONS[key]]


def sample(cov, x, y):
    """Bilinear coverage at a fractional position, 0 outside."""
    x0, y0 = math.floor(x), math.floor(y)
    fx, fy = x - x0, y - y0

    def at(i, j):
        return cov[j][i] if 0 <= i < 16 and 0 <= j < 16 else 0.0
    return (at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy)
            + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy)


def glyph(key, colour, scale=1.0):
    """An octicon quantised for LEDs: a lit pixel, a dim edge, or nothing.
    `scale` draws it about the centre (the star's pop-in)."""
    cov, f = coverage(key), blank()
    for y in range(16):
        for x in range(16):
            a = cov[y][x] if scale == 1.0 else sample(cov, (x - 7.5) / scale + 7.5, (y - 7.5) / scale + 7.5)
            if a >= FULL:
                f[y][x] = colour
            elif a >= EDGE:
                f[y][x] = tint(colour, EDGE_TINT)
    return f


def lit(key):
    return {(x, y) for y, row in enumerate(coverage(key)) for x, a in enumerate(row) if a >= FULL}


def octocat(dim=False):
    """GitHub's mark in a steady grey with a diagonal shine sweeping across it
    every loop — an icon that animates continuously while shown. Dimmed and
    still when the tile has nothing to show."""
    base = DIM if dim else MARK
    still = glyph("mark", base)
    if dim:
        return [(still, 1000)]
    body = lit("mark")
    frames = []
    for k in range(-2, 34, 2):
        f = [row[:] for row in still]
        for x, y in body:
            d = abs((x + y) - k)
            if d <= 1:
                f[y][x] = SHINE if d == 0 else WHITE
        frames.append((f, 60))
    return [(still, 2400)] + frames


SPARKS = [(1, 2), (14, 1), (0, 12), (15, 12), (2, 15), (13, 15)]


def star_icon():
    """Pops in (small -> overshoot -> settle), then twinkles: sparks in the
    empty corners blink in turn for as long as the celebration lasts."""
    pop = [(glyph("star", STAR_CORE, s), 70) for s in (0.3, 0.55, 0.8, 1.12, 1.0)]
    base = glyph("star", STAR_CORE)
    loop = []
    for x, y in SPARKS:
        f = [row[:] for row in base]
        if f[y][x] is None:
            f[y][x] = SHINE
        loop.append((f, 240))
    return pop, loop


def pulse(key, colour, order):
    """The octicon lit steadily, with a bright band travelling across its
    lit pixels in `order` (a key per pixel) — a commit running along the
    branch — then a rest."""
    base = glyph(key, colour)
    body = sorted(lit(key), key=order)
    steps = sorted({order(p) for p in body})
    frames = []
    for s in steps:
        f = [row[:] for row in base]
        for p in body:
            if order(p) == s:
                f[p[1]][p[0]] = SHINE
        frames.append((f, 70))
    return frames + [(base, 700)]


def fork_icon():
    """GitHub's fork glyph; a commit runs down from the two tips to the base."""
    return pulse("fork", FORK, lambda p: p[1])


def pr_icon():
    """GitHub's pull-request glyph; a commit runs up the incoming branch and
    across the arrow into the base branch."""
    return pulse("pr", PR, lambda p: (15 - p[1]) if p[0] >= 8 else 99)


def nodata_icon():
    return wgen.icon_frames("nodata")


# ---- reading ------------------------------------------------------------------------


class Reading:
    def __init__(self, repo, stars, forks, prs, ci=None):
        """ci: the default branch's rollup — success | failure | pending, or
        None when the repo has no checks (the lamp is then absent)."""
        self.repo, self.stars, self.forks, self.prs, self.ci = repo, stars, forks, prs, ci


class Config:
    def __init__(self, short_name=None, change_ms=10_000, celebrate_ms=8_000,
                 show_forks=True, show_prs=True, show_ci=True, main="stars"):
        """show_*: the tile's Show toggles. main: the Main watch — which of
        stars | prs | forks | ci holds the hero; it is always shown whatever
        its Show toggle says. The name line always rotates first."""
        self.short_name, self.change_ms, self.celebrate_ms = short_name, change_ms, celebrate_ms
        self.show_forks, self.show_prs, self.show_ci = show_forks, show_prs, show_ci
        self.main = main


def compact(n):
    """The hero's number: exact below 10 000 — four big digits are all that fit
    beside the big star — then whole thousands, then millions."""
    if n < 10_000:
        return str(n)
    if n < 1_000_000:
        return f"{n // 1000}k"
    return f"{n // 1_000_000}m"


def display_name(repo, short_name):
    """What the ticker calls the repo: the short name when one is set,
    otherwise the repo without its owner — lowercased, because the font draws
    lowercase and GitHub names compare case-insensitively. A name wider than
    the area scrolls its overflow (the user's call for repo names, 2026-09-23:
    a repo is named at the source, and making every long one type a short name
    was friction); the short name stays as an override."""
    return (short_name or repo.split("/")[-1]).lower()


# ---- the right area ------------------------------------------------------------------


def hero(text, colour, star=False, mark=None):
    """The count in the big face, after its mark (`★` when `star`) and 1 px."""
    a = Area()
    x = 0
    mark = "★" if star else mark
    if mark:
        x = a.text(mark, 0, 0, colour, B) + 1
    a.text(text, x, 0, colour, B)
    return a


def line_area(parts):
    """A 5 px line; parts [(text, colour)] — a grey word label gets 3 px after
    it, a value 2 px (tc002-tile-screen)."""
    a = Area(AREA_W, 5)
    x = 0
    for s, c in parts:
        x = a.text(s, x, 0, c, G) - 1 + gap_after(s, c)
    return a


MARKS = {"☺"}


def gap_after(s, c):
    """tc002-tile-screen: 3 px after a grey word label, 1 px after a mark,
    2 px after a value."""
    return 1 if s in MARKS else (3 if c == LABEL else 2)


def parts_width(parts):
    return sum(width(s) for s, _ in parts) + sum(gap_after(s, c) for s, c in parts[:-1])


ICON_STEP = wgen.ICON_STEP        # Hybrid: the icon slides 3 rows per ticker step


def area_frame(top, cur, nxt, k):
    """The right 34x16: the hero fixed on rows 0-8, the ticker line on rows
    11-15 shifted up k rows towards `nxt` (5 rows + 1 blank pitch)."""
    g = [[None] * AREA_W for _ in range(H)]
    for y in range(9):
        g[y] = top.px[y][:]
    for r in range(5):
        src = r + k
        row = cur.px[src] if src < 5 else (nxt.px[src - 6] if nxt and 6 <= src < 11 else None)
        if row:
            g[11 + r] = row[:]
    return g


def rest(loop):
    """The frame an icon rests on — its longest — which is what a slide
    carries away."""
    return max(loop, key=lambda fm: fm[1])[0]


def ticker_segments(top, states):
    """states: [(icon loop, [(line Area, ms), ...])] — a line is one still
    dwell or an edge marquee's steps. Each state holds, then its line slides up
    1 row per step while, when the next state brings a different icon, the
    icon slides up 3 rows per step over the SAME steps (Hybrid): both land
    together. Returns lace() segments."""
    segs = []
    n = len(states)
    for i, (icon, seq) in enumerate(states):
        for line, ms in seq:
            segs.append((icon, area_frame(top, line, None, 0), ms))
        if n == 1:
            break
        nicon, nseq = states[(i + 1) % n]
        cur, nxt = seq[-1][0], nseq[0][0]
        for k in range(1, SLIDE):
            area = area_frame(top, cur, nxt, k)
            if nicon is icon:
                segs.append((icon, area, STEP_MS))
                continue
            last, first = rest(icon), rest(nicon)
            shift = ICON_STEP * k
            ic = [last[y + shift] if y + shift < 16 else
                  (first[y + shift - 18] if 18 <= y + shift < 34 else [None] * 16) for y in range(16)]
            segs.append((ic, area, STEP_MS))
    return segs


def lace(segments):
    """segments: [(icon, 34x16 area, ms)], icon a loop [(16x16, ms)] or one
    16x16 grid (a slide step). Returns ONE 52x16 timeline. A loop's phase runs
    on across consecutive segments that share it, so an icon keeps animating
    through a marquee's 100 ms steps instead of restarting on each."""
    out = []

    def emit(grid, ms):
        if ms < 20 and out:
            out[-1] = (out[-1][0], out[-1][1] + ms)
        else:
            out.append((grid, ms))

    phase_of, t = None, 0
    for icon, area, ms in segments:
        if not (icon and isinstance(icon[0], tuple)):
            emit(compose(icon, area), ms)
            phase_of = None
            continue
        if icon is not phase_of:
            phase_of, t = icon, 0
        total, left = wgen.loop_ms(icon), ms
        while left > 0:
            pos, acc = t % total, 0
            for f, d in icon:
                if pos < acc + d:
                    break
                acc += d
            span = min(acc + d - pos, left)
            emit(compose(f, area), span)
            t += span
            left -= span
    return out


# ---- ambient ---------------------------------------------------------------------------


def line_state(parts, dwell):
    """A ticker line as its states: one still dwell, or an edge marquee when
    it is wider than the area."""
    if parts_width(parts) <= AREA_W:
        return [(line_area(parts), dwell)]
    return edge_marquee(parts, dwell)


# Why there is no reading, each said in the label slot — a reader fixes a bad
# token and a mistyped repo differently, and one "no data" for both hid which:
# token = GitHub answered 401; repo = the repo is not there or the token cannot
# see it (GraphQL NOT_FOUND); data = network, rate limit, outage.
PROBLEMS = {"token": "bad token", "repo": "no repo", "data": "no data"}


def ambient(r, cfg, has_token=True, problem=None):
    """Hybrid: the stars hold the hero; each ticker line brings its own icon —
    the mark with the repo's name, the fork glyph with the fork count, the PR
    glyph with the open PRs — so a count is named by its icon, not a word.
    A hidden count (Show toggles) leaves the rotation; with both hidden the
    name holds the line alone."""
    if not has_token:
        return lace(ticker_segments(Area(), [(octocat(dim=True), [(line_area([("no token", DIM)]), 1000)])]))
    if r is None or problem:
        label = PROBLEMS[problem or "data"]
        icon = nodata_icon() if (problem or "data") == "data" else octocat(dim=True)
        return lace(ticker_segments(Area(), [(icon, [(line_area([(label, DIM)]), 1000)])]))
    main = cfg.main
    states = [(octocat(), line_state([(display_name(r.repo, cfg.short_name), WHITE)], cfg.change_ms))]
    # The counts the hero does not hold, in the ticker: the stars (no Show
    # toggle — always there) once they have left the hero, then forks and PRs
    # as Show says.
    if main != "stars":
        states.append((star_icon()[1], line_state([(str(r.stars), STAR)], cfg.change_ms)))
    if cfg.show_forks and main != "forks":
        states.append((fork_icon(), line_state([(str(r.forks), FORK)], cfg.change_ms)))
    if cfg.show_prs and main != "prs":
        states.append((pr_icon(), line_state([(str(r.prs), PR)], cfg.change_ms)))
    if main == "ci":
        # The hero says the branch's CI in words; a label wider than the area
        # edge-marquees over the whole timeline, like the lamp paints over it.
        # No lamp: the hero already says it.
        text, colour = CI_HERO[r.ci if r.ci in CI_HERO else None]
        parts = [(text, colour)]
        if parts_width(parts) <= AREA_W:
            top = Area()
            top.text(text, 0, CI_HERO_Y, colour, G)
            return lace(ticker_segments(top, states))
        return with_hero(lace(ticker_segments(Area(), states)), edge_marquee(parts, 0))
    count, colour, mark = {"stars": (r.stars, STAR, "★"), "forks": (r.forks, FORK, "⑂"),
                           "prs": (r.prs, PR, "⎇")}[main]
    frames = lace(ticker_segments(hero(compact(count), colour, mark=mark), states))
    loop = lamp_loop(r.ci) if cfg.show_ci else None
    return with_lamp(frames, loop) if loop else frames


# Main watch = CI: the hero is the default branch's checks in words, in the
# line font, coloured by state — GitHub's check colours, the pending state
# called "processed" (the user's word). A repo without checks says so, dim.
CI_HERO = {
    "success": ("ci passed", PR),
    "pending": ("ci processed", CI_PENDING),
    "failure": ("ci failed", CI_FAIL),
    None: ("no ci", DIM),
}
CI_HERO_Y = 2                     # the 5 px line centred on the hero's 9 rows


def with_hero(frames, loop):
    """Paints an edge-marqueeing hero line over a whole timeline, looping, its
    phase running on across every frame (one GIF) — `with_lamp`'s cut: a
    frame that spans a step of the marquee is cut there."""
    total = sum(ms for _, ms in loop)
    out, t = [], 0
    for grid, ms in frames:
        left = ms
        while left > 0:
            pos, acc = t % total, 0
            for line, d in loop:
                if pos < acc + d:
                    break
                acc += d
            span = min(acc + d - pos, left)
            g = [row[:] for row in grid]
            for y in range(5):
                for x in range(AREA_W):
                    g[CI_HERO_Y + y][AREA_X + x] = line.px[y][x]
            out.append((g, span))
            t += span
            left -= span
    return out


# ---- the CI lamp -------------------------------------------------------------------------
#
# The default branch's checks, as a 3x3 badge on the icon's bottom-right corner
# — a status dot on an avatar. Picked in the browser over a column beside the
# hero (it touched a fourth digit) and one in the gutter (2026-09-23). It shows
# only while something needs a look: a green lamp on every healthy repo was "too
# much", so success draws nothing, like a repo without checks. Colour alone does
# not read on the dim panel (tc002-tile-screen), so the two states differ in
# motion too: pending fills from a ring to a full square and back, failure blinks.

LAMP_CELLS = [(x, y) for y in range(13, 16) for x in range(13, 16)]
LAMP_MS = 500


def lamp_loop(state):
    """[(cells {(x, y): colour}, ms)] — one loop of the lamp, or None when there
    is nothing to show (success, or no checks)."""
    if state == "failure":
        return [({p: CI_FAIL for p in LAMP_CELLS}, LAMP_MS), ({}, LAMP_MS)]
    if state == "pending":
        ring = {p: CI_PENDING for p in LAMP_CELLS if p != (14, 14)}
        return [(ring, LAMP_MS), ({p: CI_PENDING for p in LAMP_CELLS}, LAMP_MS)]
    return None


def with_lamp(frames, loop):
    """Paints the lamp over a whole timeline, its phase running on across every
    frame (one GIF, tc002-ticker-motion): a frame that spans a lamp change is
    cut there."""
    total = sum(ms for _, ms in loop)
    out, t = [], 0
    for grid, ms in frames:
        left = ms
        while left > 0:
            pos, acc = t % total, 0
            for cells, d in loop:
                if pos < acc + d:
                    break
                acc += d
            span = min(acc + d - pos, left)
            g = [row[:] for row in grid]
            for (x, y), c in cells.items():
                g[y][x] = c
            out.append((g, span))
            t += span
            left -= span
    return out


def ci_icon():
    """GitHub's failed-check glyph in red; the disc brightens and settles in
    turn for as long as the event lasts."""
    cov = coverage("ci")

    def disc(colour):
        # The cross is holes in the disc; at LED scale holes read as a plain
        # disc, so the holes inside it are lit white.
        f = glyph("ci", colour)
        for y in range(16):
            for x in range(16):
                if cov[y][x] < EDGE and (x - 7.5) ** 2 + (y - 7.5) ** 2 <= 36:
                    f[y][x] = WHITE
        return f
    return [(disc(CI_FAIL), 400), (disc(hexrgb("#FF9A92")), 400)]


# ---- celebration ------------------------------------------------------------------------

MAX_LOGINS = 3


def edge_marquee(parts, dwell_ms):
    """A value wider than 34 px scrolls only its overflow: 1 s at the start,
    1 px per 100 ms, 1.5 s at the end (tc002-ticker-motion)."""
    full = Area(parts_width(parts) + 1, 5)
    x = 0
    for s, c in parts:
        x = full.text(s, x, 0, c, G) - 1 + gap_after(s, c)
    over = full.w - 1 - AREA_W
    out = []
    for off in range(over + 1):
        a = Area(AREA_W, 5)
        for y in range(5):
            a.px[y] = full.px[y][off:off + AREA_W] + [None] * max(0, AREA_W - (full.w - off))
        ms = 1000 if off == 0 else (1500 if off == over else 100)
        out.append((a, ms))
    spent = sum(ms for _, ms in out)
    if spent < dwell_ms:
        out[-1] = (out[-1][0], out[-1][1] + dwell_ms - spent)
    return out


def celebration(kind, count, who, cfg, pr_numbers=()):
    """kind: star | fork | pr. who: logins, newest first. The icon pops in,
    `+N` holds the hero rows, and the ticker names the event and then who —
    at most three logins, the rest as `+K more`."""
    colour, (pop, loop) = {
        "star": (STAR, star_icon()),
        "fork": (FORK, ([], fork_icon())),
        "pr": (PR, ([], pr_icon())),
        "ci": (CI_FAIL, ([], ci_icon())),
    }[kind]
    if kind == "ci":
        # DRAFT (2026-09-23): `count` is unused; `who` is the head commit's
        # author, `pr_numbers` carries the branch name.
        top = hero("ci", colour)
        branch = pr_numbers[0] if pr_numbers else "main"
        lines = [[(branch, WHITE), ("fail", CI_FAIL)]]   # `main failed` is 36 px
        lines += [[("☺", PERSON), (login.lower(), WHITE)] for login in who[:1]]
        return _celebration_timeline(top, lines, pop, loop, cfg)
    top = hero(f"+{count}", colour)
    noun = {"star": ("star", "stars"), "fork": ("fork", "forks"), "pr": ("pr", "prs")}[kind][count != 1]
    label = [(noun, LABEL)]
    if kind == "pr" and len(pr_numbers) == 1:
        label = [("pr", LABEL), (f"#{pr_numbers[0]}", PR)]
    lines = [label]
    for i, login in enumerate(who[:MAX_LOGINS]):
        if kind == "pr" and len(pr_numbers) > 1:
            # The number already says whose line this is; `@` would cost the
            # 6 px that push a short login past 34.
            lines.append([(f"#{pr_numbers[i]}", PR), (login.lower(), WHITE)])
        else:
            lines.append([("☺", PERSON), (login.lower(), WHITE)])
    if len(who) > MAX_LOGINS:
        lines.append([(f"+{len(who) - MAX_LOGINS}", colour), ("more", LABEL)])
    return _celebration_timeline(top, lines, pop, loop, cfg)


def _celebration_timeline(top, lines, pop, loop, cfg):
    slides = (len(lines) - 1) * (SLIDE - 1) * STEP_MS
    dwell = max(1200, (cfg.celebrate_ms - slides) // len(lines))
    # One icon for the whole celebration: every state shares the loop, so it
    # never slides and its phase runs on across lines and marquee steps. The
    # last line does not slide back to the first — the celebration ends there
    # and the page's own frame returns.
    states = [(loop, line_state(parts, dwell)) for parts in lines]
    segs = ticker_segments(top, states)
    if len(states) > 1:
        segs = segs[:-(SLIDE - 1)]
    # The pop plays over the first dwell's opening, then the loop takes over.
    t_pop = sum(ms for _, ms in pop)
    icon, first, ms0 = segs[0]
    segs[0] = (icon, first, max(20, ms0 - t_pop))
    return [(compose(f, first), d) for f, d in pop] + lace(segs)


# ---- cases --------------------------------------------------------------------------------

R = Reading
CASES = [
    dict(id="a1-steady", desc="обычный вид: tea-rags, 1 234 ★, 45 форков, 3 PR", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3)),
    dict(id="a2-four-digits", desc="худший точный случай: 9 999 ★ (4 big-цифры рядом со звездой)", kind="ambient",
         reading=R("artk0de/tea-rags", 9999, 812, 27)),
    dict(id="a3-thousands", desc="≥ 10 000 ★ → целые тысячи: 12 345 → 12k", kind="ambient",
         reading=R("artk0de/tea-rags", 12345, 1203, 58)),
    dict(id="a4-100k", desc="123 456 ★ → 123k (ровно 34 px)", kind="ambient",
         reading=R("facebook/react", 123456, 45012, 912)),
    dict(id="a5-zero", desc="новый репо: 0 ★, 0 форков, 0 PR — ноль это данные, не пропуск", kind="ambient",
         reading=R("artk0de/pixelclocktiles", 0, 0, 0)),
    dict(id="a6-long-name", desc="длинное имя (typescript-language-server) → бегущая строка: стоит 1 s, "
         "едет только хвост 1 px / 100 ms, держится 1.5 s; dwell растягивается под проход",
         kind="ambient", reading=R("typescript-language-server/typescript-language-server", 2031, 130, 12)),
    dict(id="a7-short-name", desc="то же репо с коротким именем из настроек (необязательный override): tsls",
         kind="ambient", reading=R("typescript-language-server/typescript-language-server", 2031, 130, 12),
         short_name="tsls"),
    dict(id="a8-no-data", desc="нет данных (сеть, 404, rate limit)", kind="ambient", reading=None),
    dict(id="a9-no-token", desc="PAT не задан ни на одной GitHub-плитке", kind="ambient", reading=R("x/y", 0, 0, 0),
         token=False),
    dict(id="c1-star-one", desc="празднование: +1 звезда (на всех наших страницах)", kind="star", count=1,
         who=["alice"]),
    dict(id="c2-star-three", desc="+3 звезды — три логина", kind="star", count=3, who=["alice", "bob", "carol"]),
    dict(id="c3-star-many", desc="+7 звёзд — три логина и «+4 more»", kind="star", count=7,
         who=["alice", "bob", "carol", "dave", "eve", "frank", "grace"]),
    dict(id="c4-fork", desc="+1 форк (только своя страница)", kind="fork", count=1, who=["carol"]),
    dict(id="c5-pr-one", desc="новый PR #42 (только своя страница)", kind="pr", count=1, who=["dave"], prs=[42]),
    dict(id="c6-pr-two", desc="два новых PR — номер и автор в строке", kind="pr", count=2, who=["dave", "eve"],
         prs=[42, 43]),
    dict(id="c7-long-login", desc="длинный логин не влезает → edge-marquee (значение, не имя)", kind="star",
         count=1, who=["a-really-long-github-login"]),
    dict(id="a10-ci-pending", desc="CI main идёт: янтарный бейдж на углу иконки, наливается кольцо → квадрат",
         kind="ambient", reading=R("artk0de/tea-rags", 1234, 45, 3, ci="pending")),
    dict(id="a11-ci-failure", desc="CI main упал: красный бейдж мигает 500/500 мс", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3, ci="failure")),
    dict(id="a12-ci-success", desc="CI main зелёный: бейджа нет (как у репо без CI)", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3, ci="success")),
    dict(id="a13-ci-worst", desc="худший бюджет: длинное имя (marquee) + мигающий бейдж — 353 кадра при 10 s",
         kind="ambient", reading=R("typescript-language-server/typescript-language-server", 9999, 45012, 912,
                                   ci="failure")),
    dict(id="c8-ci-failed", desc="событие: main упал (только своя страница) — иконка failed-check, "
         "hero «ci», «main fail», автор коммита", kind="ci", count=1, who=["dave"], prs=["main"]),
    dict(id="a14-bad-token", desc="GitHub ответил 401: токен неверный, отозван или истёк", kind="ambient",
         reading=None, problem="token"),
    dict(id="a15-no-repo", desc="репо не найден или токену недоступен (опечатка, приватный без доступа)",
         kind="ambient", reading=None, problem="repo"),
    dict(id="a16-no-forks", desc="Show: форки выключены — крутятся имя и PR", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3), show_forks=False),
    dict(id="a17-name-only", desc="Show: форки и PR выключены — имя стоит на строке одно", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3), show_forks=False, show_prs=False),
    dict(id="a18-ci-hidden", desc="Show: CI выключен — main упал, но бейджа нет", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3, ci="failure"), show_ci=False),
    dict(id="a19-main-prs", desc="Main watch = PRs: PR в hero, в тикере имя, звёзды, форки", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3), main="prs"),
    dict(id="a20-main-forks", desc="Main watch = Forks: форки в hero, в тикере имя, звёзды, PR", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 12345, 3), main="forks"),
    dict(id="a21-main-ci-passed", desc="Main watch = CI: «ci passed» зелёным, без бейджа", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3, ci="success"), main="ci"),
    dict(id="a22-main-ci-processed", desc="Main watch = CI: «ci processed» янтарным — шире 34 px, edge-marquee",
         kind="ambient", reading=R("artk0de/tea-rags", 1234, 45, 3, ci="pending"), main="ci"),
    dict(id="a23-main-ci-failed", desc="Main watch = CI: «ci failed» красным", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3, ci="failure"), main="ci"),
    dict(id="a24-main-no-ci", desc="Main watch = CI у репо без проверок: «no ci» тускло", kind="ambient",
         reading=R("artk0de/tea-rags", 1234, 45, 3), main="ci"),
    dict(id="a25-main-prs-hidden", desc="Main watch = PRs при выключенных Show PRs и Forks: PR всё равно в hero",
         kind="ambient", reading=R("artk0de/tea-rags", 1234, 45, 912), main="prs", show_prs=False,
         show_forks=False),
    dict(id="a26-main-ci-worst", desc="худший бюджет Main watch: длинное имя (marquee) + «ci processed» (marquee) "
         "+ четыре состояния тикера", kind="ambient",
         reading=R("typescript-language-server/typescript-language-server", 9999, 45012, 912, ci="pending"),
         main="ci"),
]
# The review page for the Main watch round (2026-09-24): the new states,
# beside a1 as the face they are read against.
CASES_REVIEW = [c for c in CASES if c["id"] == "a1-steady" or c["id"].startswith(
    ("a19", "a20", "a21", "a22", "a23", "a24", "a25", "a26"))]

DWELLS = [3000, 5000, 8000, 10000, 15000]
CELEBRATES = [5000, 8000, 10000, 15000]


def build(case, dwell=10_000, celebrate=8_000):
    cfg = Config(case.get("short_name"), dwell, celebrate, case.get("show_forks", True),
                 case.get("show_prs", True), case.get("show_ci", True), case.get("main", "stars"))
    if case["kind"] == "ambient":
        return ambient(case["reading"], cfg, case.get("token", True), case.get("problem"))
    return celebration(case["kind"], case["count"], case["who"], cfg, tuple(case.get("prs", ())))


def packed(frames):
    return {"frames": [hexrows(g) for g, _ in frames], "ms": [ms for _, ms in frames]}


def key_frames(frames, limit=6):
    """Indices worth a still: where the right area has just settled on new
    content (it differs from the frame before and holds into the frame after),
    so a still lands on every dwell whatever the icon is doing — plus, for an
    icon that pops in, the first frame after the pop."""
    area = [tuple(tuple(r[AREA_X:]) for r in g) for g, _ in frames]
    keys = [0]
    for i in range(1, len(frames) - 1):
        if area[i] != area[i - 1] and area[i] == area[i + 1]:
            keys.append(i)
    if len(frames) > 5 and area[5] == area[0]:
        keys[0] = 5
    return sorted(set(keys))[:limit]


def main():
    out_dir = os.path.join(HERE, "out")
    os.makedirs(out_dir, exist_ok=True)
    cases, report = [], []
    for c in CASES_REVIEW:
        variants = {}
        values = DWELLS if c["kind"] == "ambient" else CELEBRATES
        for v in values:
            frames = build(c, dwell=v) if c["kind"] == "ambient" else build(c, celebrate=v)
            variants[str(v)] = {**packed(frames), "keys": key_frames(frames)}
            if v == (10_000 if c["kind"] == "ambient" else 8_000):
                ok = fits(frames)
                total = sum(ms for _, ms in frames)
                report.append(f"{c['id']:18} frames={len(frames):3} total={total / 1000:5.1f}s fits={ok}")
                for n, k in enumerate(key_frames(frames)):
                    sheet.png(frames[k][0], os.path.join(out_dir, f"{c['id']}-{n}.png"), cell=10, dot=8)
        cases.append({"id": c["id"], "desc": c["desc"], "kind": c["kind"], "variants": variants})
    data = {"W": W, "H": H, "cases": cases, "dwells": DWELLS, "celebrates": CELEBRATES}
    tpl = open(os.path.join(HERE, "gtemplate.html"), encoding="utf-8").read()
    with open(os.path.join(HERE, "index.html"), "w", encoding="utf-8") as f:
        f.write(tpl.replace("/*DATA*/null", json.dumps(data, separators=(",", ":"))))
    print("\n".join(report))
    print(os.path.join(HERE, "index.html"), len(cases), "cases")


if __name__ == "__main__":
    main()
