#!/usr/bin/env python3
"""Live TC002 demo of the shared usage face (Claude / Z.AI).

Pixels come from gen.py — the same code the approved HTML mockups play — so
the clock shows exactly what was approved. The page is one full-frame GIF89a
with PER-FRAME delays (percent phase = --interval, reset phase, marquee steps),
pushed as a DIY app under a demo name so the running app never overwrites it.

  python3 tc002_demo.py                      # live Claude + sample Z.AI, show Claude
  python3 tc002_demo.py --show zai
  python3 tc002_demo.py --scenario both-hot  # corner cases, both vendors
  python3 tc002_demo.py --interval 5         # Show reset every 5 s
  python3 tc002_demo.py --threshold 70       # Show reset after 70% usage (50..100 step 5)
  python3 tc002_demo.py --marquee full        # enter right / exit left (1px: >50 frames, probes the limit)
  python3 tc002_demo.py --remove             # delete the demo pages
"""
import argparse, base64, calendar, json, os, sys, time, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen  # noqa: E402

HOST = os.environ.get("TC002_HOST", "192.168.1.72")
PAGES = {"claude": "demo-claude", "zai": "demo-zai"}
STATUS = os.path.expanduser("~/Library/Application Support/PixelClockTiles/claude-status.json")
INTERVALS = {"5": 5, "10": 10, "15": 15, "30": 30, "1m": 60, "2m": 120, "5m": 300}


# ── reset formatting: always the Mac's own time zone ──
def rst_session(epoch):
    return time.strftime("%H:%M", time.localtime(epoch))


MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()


def rst_week(epoch):
    t = time.localtime(epoch)  # "25 sep 18:00" — the way Claude's API words it
    return f"{t.tm_mday} {MONTHS[t.tm_mon - 1]} {t.tm_hour:02d}:{t.tm_min:02d}"


def claude_live():
    d = json.load(open(STATUS))["rate_limits"]
    f, s = d["five_hour"], d["seven_day"]
    return (gen.R(round(f["used_percentage"]), rst_session(f["resets_at"])),
            gen.R(round(s["used_percentage"]), rst_week(s["resets_at"])))


def shanghai_to_epoch(y, mo, d, h, mi):
    """A reset stated in China time (UTC+8, no DST) as an absolute instant."""
    return calendar.timegm((y, mo, d, h, mi, 0)) - 8 * 3600


def zai_sample():
    # z.ai's server lives in Asia/Shanghai: 5h window resets 21:00 CST today-ish,
    # weekly 28.09 21:00 CST — shown converted to the Mac's zone.
    now = time.gmtime()
    sess = shanghai_to_epoch(now.tm_year, now.tm_mon, now.tm_mday, 21, 0)
    week = shanghai_to_epoch(2026, 9, 28, 21, 0)
    return gen.R(83, rst_session(sess)), gen.R(47, rst_week(week))


SCENARIOS = {
    "steady": (gen.R(23), gen.R(41)),
    "s-hot": (gen.R(84, "14:30"), gen.R(52)),
    "w-hot": (gen.R(35), gen.R(92, "26 sep 15:00")),
    "both-hot": (gen.R(97, "09:05"), gen.R(88, "1 oct 09:00")),
    "spent": (gen.R(104, "23:59"), gen.R(100, "30 sep 23:59")),
    "zero": (gen.R(0), gen.R(3)),
    "no-data": (gen.R(None), gen.R(None)),
    "threshold": (gen.R(72, "18:10"), gen.R(61, "28 sep 16:00")),
}


# ── full-frame GIF89a with per-frame delays (MakeTimedGif.py's writer) ──
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


def gif(frames):
    """frames: [(gen.Canvas, ms)] → GIF bytes, full 52x16 frames, one palette."""
    W, H = gen.W, gen.H
    palette, indexed = {(0, 0, 0): 0}, []
    for cv, ms in frames:
        row = bytearray()
        for y in range(H):
            for x in range(W):
                c = cv.px[y][x] or (0, 0, 0)
                if c not in palette:
                    palette[c] = len(palette)
                row.append(palette[c])
        indexed.append((bytes(row), max(2, round(ms / 10))))
    colours = list(palette)
    g = bytearray(b"GIF89a") + bytes([W, 0, H, 0, 0xF7, 0, 0])
    for i in range(256):
        g += bytes(colours[i]) if i < len(colours) else b"\0\0\0"
    g += bytes([0x21, 0xFF, 11]) + b"NETSCAPE2.0" + bytes([3, 1, 0, 0, 0])
    for data, cs in indexed:
        g += bytes([0x21, 0xF9, 4, 0x04, cs & 0xFF, cs >> 8, 0, 0])
        g += bytes([0x2C, 0, 0, 0, 0, W, 0, H, 0, 0, 8])
        blob = lzw_encode(data)
        for i in range(0, len(blob), 255):
            g += bytes([len(blob[i:i + 255])]) + blob[i:i + 255]
        g.append(0)
    g.append(0x3B)
    return bytes(g)


def post(path, body):
    req = urllib.request.Request(f"http://{HOST}{path}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def push(vendor, s, w, interval_ms, step, marquee, threshold, out_dir):
    frames = gen.timeline(vendor, s, w, interval_ms, step, marquee, threshold)
    data = gif(frames)
    open(os.path.join(out_dir, f"demo-{vendor}.gif"), "wb").write(data)
    b64 = base64.b64encode(data).decode()
    total = sum(ms for _, ms in frames) / 1000
    print(f"{vendor}: s={s['pct']}% rst={s['rst'] or '-'} | w={w['pct']}% rst={w['rst'] or '-'}"
          f" → {len(frames)} frames, cycle {total:.1f}s, gif {len(data)} B, base64 {len(b64)} B")
    if len(frames) > 50 or len(b64) > 60_000:
        print(f"  ! beyond the documented limits (50 frames / 60 KB) — this push probes them")
    envelope = {"duration": 10, "image": [{"data": "data:image/gif;base64," + b64, "position": [0, 0]}]}
    print("  custom:", post(f"/api/custom?name={PAGES[vendor]}", json.dumps(envelope).encode()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", choices=SCENARIOS)
    ap.add_argument("--interval", default="10", choices=INTERVALS, help="Show reset every (s / 1m / 2m / 5m)")
    ap.add_argument("--step", type=int, default=1, help="marquee px per frame")
    ap.add_argument("--marquee", default="edge", choices=["edge", "full"], help="edge: glide to the tail and hold; full: enter right, exit left")
    ap.add_argument("--threshold", type=int, default=80, choices=range(50, 101, 5), metavar="50..100", help="Show reset after N%% usage (step 5)")
    ap.add_argument("--show", default="claude", choices=PAGES)
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()
    if a.remove:
        for name in PAGES.values():
            print(name, post(f"/api/custom?name={name}", b""))
        return
    out_dir = gen.OUT
    interval_ms = INTERVALS[a.interval] * 1000
    data = {"claude": claude_live(), "zai": zai_sample()}
    if a.scenario:
        data = {v: SCENARIOS[a.scenario] for v in PAGES}
    for vendor, (s, w) in data.items():
        push(vendor, s, w, interval_ms, a.step, a.marquee, a.threshold, out_dir)
    print("switch:", post(f"/api/switchDiyApp?name={PAGES[a.show]}", b""))
    print(f"Mac time zone: {time.strftime('%Z %z')}")


if __name__ == "__main__":
    main()
