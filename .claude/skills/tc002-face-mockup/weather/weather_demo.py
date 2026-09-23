#!/usr/bin/env python3
"""Live TC002 demo of the Better Weather face, layout A (anchor + ticker).

Pixels come from wgen.py / icons.py — the code the HTML mockups play.

  python3 weather_demo.py                       # 12-thunder, layered
  python3 weather_demo.py --scenario 10         # any case id prefix from wgen.CASES
  python3 weather_demo.py --interval 3          # ticker page every 3 s
  python3 weather_demo.py --items feels,wind    # which ticker lines, in order
  python3 weather_demo.py --no-feels-colour     # colour the temperature by the air, not the felt
  python3 weather_demo.py --mode single         # one full-frame 52x16 GIF instead of two
  python3 weather_demo.py --remove

--mode layered (default) sends ONE page with TWO GIFs in `image[]`: the icon
(16x16 at 0,0) loops on its own clock, the right area (34x16 at 18,0) carries
the temperature and the ticker with per-frame delays. Whether the TC002 plays
two GIFs at once is exactly what this probes. --mode single merges both
clocks into one 52x16 timeline (every icon step inside every dwell), which is
what we fall back to if layered does not animate both.
"""
import argparse, base64, json, os, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icons, wgen  # noqa: E402

HOST = os.environ.get("TC002_HOST", "192.168.1.72")
PAGE = "demo-weather"
ORDER = ["feels", "humidity", "wind", "hilo", "rain", "uv", "sun", "hourly"]
DEFAULT_ITEMS = "feels,humidity,wind,hilo,rain,hourly"
STEP_MS = 60          # one row of the ticker slide (a whole centisecond count: both GIFs must sum alike)
SLIDE = 6             # 5 rows + 1 blank


def all_icons():
    return {**icons.THEMES, **icons.DERIVED, **icons.MOON, **icons.PAGE_ICONS}


def lzw_encode(pixels):
    out, buf, cnt = [], 0, 0

    def emit(code, width):
        nonlocal buf, cnt
        buf |= code << cnt
        cnt += width
        while cnt >= 8:
            out.append(buf & 0xFF)
            buf >>= 8
            cnt -= 8

    width, table, phrase = 9, {bytes([i]): i for i in range(256)}, b""
    emit(256, width)
    for p in pixels:
        nxt = phrase + bytes([p])
        if nxt in table:
            phrase = nxt
            continue
        emit(table[phrase], width)
        code = len(table) + 2
        table[nxt] = code
        if code == 1 << width and width < 12:
            width += 1
        phrase = bytes([p])
    if phrase:
        emit(table[phrase], width)
    emit(257, width)
    if cnt:
        out.append(buf & 0xFF)
    return bytes(out)


def gif(frames, w, h):
    """frames: [(grid[h][w] of RGB|None, ms)] -> GIF89a, full frames, one palette."""
    palette, indexed = {(0, 0, 0): 0}, []
    for grid, ms in frames:
        row = bytearray()
        for y in range(h):
            for x in range(w):
                c = grid[y][x] or (0, 0, 0)
                if c not in palette:
                    palette[c] = len(palette)
                row.append(palette[c])
        indexed.append((bytes(row), max(2, round(ms / 10))))
    if len(palette) > 256:
        raise SystemExit(f"{len(palette)} colours > 256")
    colours = list(palette)
    g = bytearray(b"GIF89a") + bytes([w, 0, h, 0, 0xF7, 0, 0])
    for i in range(256):
        g += bytes(colours[i]) if i < len(colours) else b"\0\0\0"
    g += bytes([0x21, 0xFF, 11]) + b"NETSCAPE2.0" + bytes([3, 1, 0, 0, 0])
    for data, cs in indexed:
        g += bytes([0x21, 0xF9, 4, 0x04, cs & 0xFF, cs >> 8, 0, 0])
        g += bytes([0x2C, 0, 0, 0, 0, w, 0, h, 0, 0, 8])
        blob = lzw_encode(data)
        for i in range(0, len(blob), 255):
            g += bytes([len(blob[i:i + 255])]) + blob[i:i + 255]
        g.append(0)
    g.append(0x3B)
    return bytes(g)


def area_timeline(sc, items, feels_colour, interval_ms, hybrid=False):
    """The right 34x16: temperature fixed on rows 0-8, ticker on rows 11-15.
    Returns [(grid, ms, icon)] — icon is the weather's, or in Hybrid the one
    the line brings; it changes halfway through the slide."""
    top = wgen.big_temp(sc, feels_colour).px
    lines = wgen.detail_lines(sc)
    keys = ["nodata"] if "nodata" in lines else [k for k in items if k in lines]
    ticker = [lines[k].px for k in keys]
    weather = sc["theme"]

    def icon_of(key):
        return (wgen.item_icon(sc, key) if hybrid else None) or weather

    def frame(cur, nxt, k):
        g = [[None] * wgen.AREA_W for _ in range(16)]
        for y in range(9):
            g[y] = top[y][:]
        for r in range(5):
            src = r + k
            line = cur[src] if src < 5 else (nxt[src - 6] if 6 <= src < 11 else None)
            if line:
                g[11 + r] = line[:]
        return g

    if len(ticker) < 2:
        g = frame(ticker[0], ticker[0], 0) if ticker else frame([[None] * 34] * 5, [[None] * 34] * 5, 0)
        return [(g, 1000, icon_of(keys[0]) if keys else weather)]
    out = []
    for i, cur in enumerate(ticker):
        j = (i + 1) % len(ticker)
        nxt = ticker[j]
        out.append((frame(cur, nxt, 0), interval_ms, icon_of(keys[i])))
        for k in range(1, SLIDE):
            out.append((frame(cur, nxt, k), STEP_MS, icon_of(keys[i])))   # swaps when the line lands
    return out


def h2c(s):
    return None if s == "000000" else tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def pages_timeline(sc, items, feels_colour, interval_ms):
    """Layout B: each page is icon + big figure + label; the whole right area
    slides up 2 rows per step, the icon swaps halfway."""
    pages = [p for p in wgen.layout_b(sc)["pages"] if p["key"] == "temp" or p["key"] in items]
    grids = []
    for p in pages:
        rows = p["rows"].get("1" if feels_colour else "0") or p["rows"]["1"]
        grids.append([[h2c(r[x * 6:x * 6 + 6]) for x in range(wgen.AREA_W)] for r in rows])
    if len(pages) < 2:
        return [(grids[0], 1000, pages[0]["icon"])]
    out = []
    for i, cur in enumerate(grids):
        j = (i + 1) % len(grids)
        nxt = grids[j]
        out.append((cur, interval_ms, pages[i]["icon"]))
        for k in range(1, 9):
            g = []
            for r in range(16):
                src = r + 2 * k
                g.append(cur[src][:] if src < 16 else (nxt[src - 18][:] if 18 <= src < 34 else [None] * wgen.AREA_W))
            out.append((g, 40, pages[j]["icon"] if 2 * k >= 9 else pages[i]["icon"]))
    return out


def pages_full(sc, items, feels_colour, interval_ms, burst=None):
    """Layout B as ONE 52x16 timeline: during a dwell the icon animates beside
    a still page; on a change the WHOLE page — icon and figure together —
    slides up 2 rows per step, so the icon can never lead or trail its text."""
    tagged = pages_timeline(sc, items, feels_colour, interval_ms)
    dwell = [(g, ms, ic) for g, ms, ic in tagged if ms == interval_ms or len(tagged) == 1]
    icons_ = all_icons()

    def compose(icon_frame, area):
        g = [[None] * 52 for _ in range(16)]
        for y in range(16):
            g[y][:16] = icon_frame[y][:]
            g[y][wgen.AREA_X:] = area[y][:]
        return g

    out = []
    for i, (area, ms, name) in enumerate(dwell):
        tl = icons_[name]()
        seq = play(tl, ms, burst)
        out += [(compose(f, area), d) for f, d in seq]
        last = seq[-1][0]
        if len(dwell) < 2:
            break
        nxt_area, _, nxt_name = dwell[(i + 1) % len(dwell)]
        cur_full = compose(last, area)
        nxt_full = compose(icons_[nxt_name]()[0][0], nxt_area)
        for k in range(1, 9):
            g = []
            for r in range(16):
                src = r + 2 * k
                g.append(cur_full[src][:] if src < 16 else (nxt_full[src - 18][:] if 18 <= src < 34 else [None] * 52))
            out.append((g, 40))
    return out


def play(tl, total, burst):
    """An icon over `total` ms: whole loops until at least `burst` ms have
    played, then its first frame holds for the rest (burst=None: loop all)."""
    out, t, i = [], 0, 0
    while t < total:
        if burst is not None and t >= burst and i % len(tl) == 0:
            out.append((tl[0][0], total - t))
            break
        f, ms = tl[i % len(tl)]
        ms = min(ms, total - t)
        if ms < 20 and out:
            out[-1] = (out[-1][0], out[-1][1] + ms)
        else:
            out.append((f, ms))
        t += ms
        i += 1
    return out


def hybrid_full(sc, items, feels_colour, interval_ms, burst=None):
    """Hybrid as ONE 52x16 timeline. The temperature never moves; on a change
    the ticker line slides up 1 row per step and the icon beside it slides up
    3 rows per step over the SAME steps — both land together."""
    tagged = area_timeline(sc, items, feels_colour, interval_ms, hybrid=True)
    icons_ = all_icons()
    out = []
    i = 0
    while i < len(tagged):
        area, ms, name = tagged[i]
        tl = icons_[name]() if name else wgen.nodata_icon()
        seq = play(tl, ms, burst)
        for f, d in seq:
            g = [[None] * 52 for _ in range(16)]
            for y in range(16):
                g[y][:16] = f[y][:]
                g[y][wgen.AREA_X:] = area[y][:]
            out.append((g, d))
        last = seq[-1][0]
        j = i + 1
        slides = []
        while j < len(tagged) and tagged[j][1] != interval_ms:
            slides.append(tagged[j])
            j += 1
        nxt_i = j % len(tagged)
        nxt_name = tagged[nxt_i][2]
        nxt = (icons_[nxt_name]() if nxt_name else wgen.nodata_icon())[0][0]
        for k, (sarea, sms, _) in enumerate(slides, 1):
            shift = 3 * k
            g = [[None] * 52 for _ in range(16)]
            for y in range(16):
                src = y + shift
                g[y][:16] = last[src][:] if src < 16 else (nxt[src - 18][:] if 18 <= src < 34 else [None] * 16)
                g[y][wgen.AREA_X:] = sarea[y][:]
            out.append((g, sms))
        i = j
        if len(tagged) == 1:
            break
    return out


def synced_icon(area, burst=None):
    """The icon GIF for a layout whose icon changes with the page: each run of
    one icon plays that icon's loop for exactly the run's length, so both GIFs
    share one total duration and stay in step."""
    icons_ = all_icons()
    runs = []
    for _, ms, name in area:
        if runs and runs[-1][0] == name:
            runs[-1][1] += ms
        else:
            runs.append([name, ms])
    if len(runs) > 1 and runs[0][0] == runs[-1][0]:
        runs[0][1] += runs.pop()[1]   # the loop wraps: first and last run are one
        rotate = runs[0][1] - sum(ms for _, ms, n in area[:next(i for i, a in enumerate(area) if a[2] != runs[0][0])])
    else:
        rotate = 0
    out = []
    for name, total in runs:
        tl = icons_[name]() if name else wgen.nodata_icon()
        out += play(tl, total, burst)
    if rotate:   # start the icon GIF where the area GIF starts
        t, cut = 0, 0
        while t < rotate:
            t += out[cut][1]
            cut += 1
        out = out[cut:] + out[:cut]
    return out


def icon_timeline(sc):
    name = sc["theme"]
    return all_icons()[name]() if name else wgen.nodata_icon()


def merged(icon, area):
    """One 52x16 timeline: a new frame whenever either clock ticks."""
    def cuts(tl):
        t, out = 0, []
        for _, ms in tl:
            out.append(t)
            t += ms
        return out, t

    ic_cuts, ic_len = cuts(icon)
    ar_cuts, total = cuts(area)
    times = sorted(set(ar_cuts) | {c + k * ic_len for k in range(total // ic_len + 1) for c in ic_cuts if c + k * ic_len < total})
    frames = []
    for n, t in enumerate(times):
        end = times[n + 1] if n + 1 < len(times) else total
        ii = max(i for i, c in enumerate(ic_cuts) if c <= t % ic_len)
        ai = max(i for i, c in enumerate(ar_cuts) if c <= t)
        g = [[None] * 52 for _ in range(16)]
        for y in range(16):
            g[y][:16] = icon[ii][0][y][:]
            g[y][wgen.AREA_X:] = area[ai][0][y][:]
        frames.append((g, end - t))
    return frames


def live(sc, items, fc, interval_ms, layout, cycles):
    """The Mac drives the states: one push per ticker line. Each push is two
    independent GIFs — the line's own icon looping by itself, and the area
    holding line N, sliding to N+1, then holding N+1 — timed so the NEXT push
    lands exactly when N+1 has landed: that is where the icon changes."""
    import time
    tagged = area_timeline(sc, items, fc, interval_ms, hybrid=layout == "hybrid")
    n = len([1 for _, ms, _ in tagged if ms == interval_ms])
    per = len(tagged) // n                     # dwell + slide frames per line
    icons_ = all_icons()
    slide_ms = sum(ms for _, ms, _ in tagged[1:per])
    t0 = time.monotonic()
    for step in range(n * cycles):
        i = step % n
        block = tagged[i * per:(i + 1) * per]
        landed = tagged[((i + 1) % n) * per][0]
        area = [(block[0][0], interval_ms - slide_ms)] + [(g, ms) for g, ms, _ in block[1:]] + [(landed, 60000)]
        name = block[0][2]
        icon = icons_[name]() if name else wgen.nodata_icon()
        ig, ag = gif(icon, 16, 16), gif(area, wgen.AREA_W, 16)
        env = {"duration": 30, "image": [image(ig, 0), image(ag, wgen.AREA_X)]}
        body = json.dumps(env).encode()
        # wait for this state's slot, then push
        due = t0 + step * interval_ms / 1000
        time.sleep(max(0, due - time.monotonic()))
        r = post(f"/api/custom?name={PAGE}", body)
        if step == 0:
            post(f"/api/switchDiyApp?name={PAGE}", b"")
        print(f"t={time.monotonic() - t0:6.2f}s line {i} icon {name}: {len(body)} B {r}", flush=True)


def post(path, body):
    req = urllib.request.Request(f"http://{HOST}{path}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def image(data, x):
    return {"data": "data:image/gif;base64," + base64.b64encode(data).decode(), "position": [x, 0]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", default="12")
    ap.add_argument("--interval", type=float, default=10, help="seconds per ticker line")
    ap.add_argument("--items", default=DEFAULT_ITEMS, help="comma list of " + ",".join(ORDER))
    ap.add_argument("--no-feels-colour", action="store_true")
    ap.add_argument("--mode", choices=["layered", "single", "lockstep"], help="default: layered, single for pages")
    ap.add_argument("--layout", default="anchor", choices=["anchor", "hybrid", "pages"])
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--burst", type=int, default=0, help="pages/hybrid: ms of icon motion after each change, then rest (0 = loop all)")
    ap.add_argument("--live", type=int, metavar="CYCLES", help="Mac-driven: one push per ticker line")
    a = ap.parse_args()
    if a.remove:
        print(PAGE, post(f"/api/custom?name={PAGE}", b""))
        return
    sc = next(c for c in wgen.CASES if c["id"].startswith(a.scenario))
    items = [k for k in a.items.split(",") if k]
    fc, ms = not a.no_feels_colour, int(a.interval * 1000)
    if a.live:
        live(sc, items, fc, ms, a.layout, a.live)
        return
    if a.layout == "pages":
        tagged = pages_timeline(sc, items, fc, ms)
    else:
        tagged = area_timeline(sc, items, fc, ms, hybrid=a.layout == "hybrid")
    area = [(g, t) for g, t, _ in tagged]
    icon = icon_timeline(sc) if a.layout == "anchor" else synced_icon(tagged, a.burst or None)
    here = os.path.dirname(os.path.abspath(__file__))
    if a.layout == "pages":
        a.mode = "single"   # the icon slides with its page: one GIF by construction
    a.mode = a.mode or ("single" if a.layout == "hybrid" else "layered")
    if a.layout == "hybrid" and a.mode == "single":
        frames = hybrid_full(sc, items, fc, ms, a.burst or None)
        g = gif(frames, 52, 16)
        env = {"duration": 30, "image": [image(g, 0)]}
        print(f"{sc['id']} [hybrid]: single {len(frames)} fr / {len(g)} B (b64 {len(base64.b64encode(g))})")
    elif a.layout == "pages":
        frames = pages_full(sc, items, fc, ms, a.burst or None)
        g = gif(frames, 52, 16)
        env = {"duration": 30, "image": [image(g, 0)]}
        print(f"{sc['id']} [pages]: single {len(frames)} fr / {len(g)} B (b64 {len(base64.b64encode(g))})")
    elif a.mode == "lockstep":
        # both GIFs get the SAME cuts: every frame boundary of either clock
        # becomes a frame in both, so per-frame overhead hits them alike
        full = merged(icon, area)
        ic = [([row[:16] for row in g], ms) for g, ms in full]
        ar = [([row[wgen.AREA_X:] for row in g], ms) for g, ms in full]
        ig, ag = gif(ic, 16, 16), gif(ar, wgen.AREA_W, 16)
        env = {"duration": 30, "image": [image(ig, 0), image(ag, wgen.AREA_X)]}
        print(f"{sc['id']} [{a.layout}] lockstep: {len(full)} fr each · icon {len(ig)} B · area {len(ag)} B")
    elif a.mode == "layered":
        ig, ag = gif(icon, 16, 16), gif(area, wgen.AREA_W, 16)
        open(os.path.join(here, "demo-icon.gif"), "wb").write(ig)
        open(os.path.join(here, "demo-area.gif"), "wb").write(ag)
        env = {"duration": 30, "image": [image(ig, 0), image(ag, wgen.AREA_X)]}
        print(f"{sc['id']} [{a.layout}]: icon {len(icon)} fr / {len(ig)} B "
              f"({sum(m for _, m in icon)} ms vs area {sum(m for _, m in area)} ms) · "
              f"area {len(area)} fr / {len(ag)} B · ticker {items}")
    else:
        frames = merged(icon, area)
        g = gif(frames, 52, 16)
        open(os.path.join(here, "demo-single.gif"), "wb").write(g)
        env = {"duration": 30, "image": [image(g, 0)]}
        print(f"{sc['id']} [{a.layout}]: single {len(frames)} fr / {len(g)} B (b64 {len(base64.b64encode(g))})")
        if len(frames) > 50:
            print("  ! beyond the documented 50 frames — this push probes the limit")
    body = json.dumps(env).encode()
    print("  payload", len(body), "B")
    print("  custom:", post(f"/api/custom?name={PAGE}", body))
    print("  switch:", post(f"/api/switchDiyApp?name={PAGE}", b""))


if __name__ == "__main__":
    main()
