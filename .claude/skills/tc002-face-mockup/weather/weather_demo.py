#!/usr/bin/env python3
"""Live TC002 demo of the Better Weather face: Anchor, Hybrid, Pages.

Pixels AND timelines come from wgen.py / icons.py — the code the HTML
mockups play and the Swift face's oracle records. This file only picks a
scenario, encodes the GIFs and pushes them.

  python3 weather_demo.py                       # 12-thunder, layered
  python3 weather_demo.py --scenario 10         # any case id prefix from wgen.CASES
  python3 weather_demo.py --interval 3          # ticker page every 3 s
  python3 weather_demo.py --items feels,wind    # which ticker lines, in order
  python3 weather_demo.py --no-feels-colour     # colour the temperature by the air, not the felt
  python3 weather_demo.py --mode single         # one full-frame 52x16 GIF instead of two
  python3 weather_demo.py --layout hybrid       # or pages: one 52x16 GIF, with the budget rule
  python3 weather_demo.py --layout pages --burst 2000   # force the burst fallback
  python3 weather_demo.py --remove

--mode layered (default) sends ONE page with TWO GIFs in `image[]`: the icon
(16x16 at 0,0) loops on its own clock, the right area (34x16 at 18,0) carries
the temperature and the ticker with per-frame delays. Whether the TC002 plays
two GIFs at once is exactly what this probes. --mode single merges both
clocks into one 52x16 timeline (every icon step inside every dwell), which is
what we fall back to if layered does not animate both.
"""
import argparse, base64, json, os, sys, urllib.request
from datetime import timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wgen  # noqa: E402

HOST = os.environ.get("TC002_HOST", "192.168.1.72")
PAGE = "demo-weather"
ORDER = wgen.ORDER
DEFAULT_ITEMS = ",".join(wgen.DEFAULT_ITEMS)
gif = wgen.gif


def view(sc, items, feels_colour, interval_ms, layout):
    cfg = wgen.case_config(sc, layout=layout, change_ms=interval_ms, feels_colour=feels_colour,
                           items=tuple(items))
    return wgen.View(sc["reading"], cfg, sc["now"], timezone.utc)


def synced_icon(area, burst=None):
    """The icon GIF for a layout whose icon changes with the page: each run of
    one icon plays that icon's loop for exactly the run's length, so both GIFs
    share one total duration and stay in step."""
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
        out += wgen.play(wgen.icon_frames(name), total, burst)
    if rotate:   # start the icon GIF where the area GIF starts
        t, cut = 0, 0
        while t < rotate:
            t += out[cut][1]
            cut += 1
        out = out[cut:] + out[:cut]
    return out


def icon_timeline(v):
    return wgen.icon_frames(v.icon)


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


def live(v, cycles):
    """The Mac drives the states: one push per ticker line. Each push is two
    independent GIFs — the line's own icon looping by itself, and the area
    holding line N, sliding to N+1, then holding N+1 — timed so the NEXT push
    lands exactly when N+1 has landed: that is where the icon changes."""
    import time
    tagged = wgen.area_timeline(v, hybrid=v.cfg.layout == "hybrid")
    interval_ms = v.cfg.change_ms
    n = len([1 for _, ms, _ in tagged if ms == interval_ms])
    per = len(tagged) // n                     # dwell + slide frames per line
    slide_ms = sum(ms for _, ms, _ in tagged[1:per])
    t0 = time.monotonic()
    for step in range(n * cycles):
        i = step % n
        block = tagged[i * per:(i + 1) * per]
        landed = tagged[((i + 1) % n) * per][0]
        area = [(block[0][0], interval_ms - slide_ms)] + [(g, ms) for g, ms, _ in block[1:]] + [(landed, 60000)]
        name = block[0][2]
        icon = wgen.icon_frames(name)
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
    v = view(sc, items, fc, ms, a.layout)
    if a.live:
        live(v, a.live)
        return
    tagged = wgen.area_timeline(v, hybrid=a.layout == "hybrid")
    area = [(g, t) for g, t, _ in tagged]
    icon = icon_timeline(v) if a.layout == "anchor" else synced_icon(tagged, a.burst or None)
    here = os.path.dirname(os.path.abspath(__file__))
    if a.layout == "pages":
        a.mode = "single"   # the icon slides with its page: one GIF by construction
    a.mode = a.mode or ("single" if a.layout == "hybrid" else "layered")
    if a.layout in ("hybrid", "pages") and a.mode == "single":
        # the face's own timeline; --burst forces the fallback the budget rule picks
        if a.burst:
            build = wgen.pages_full if a.layout == "pages" else wgen.hybrid_full
            frames, burst = build(v, a.burst), a.burst
        else:
            frames, burst = wgen.full_timeline(v)
        g = gif(frames, 52, 16)
        env = {"duration": 30, "image": [image(g, 0)]}
        print(f"{sc['id']} [{a.layout}] icon {v.icon}: single {len(frames)} fr / {len(g)} B "
              f"(b64 {len(base64.b64encode(g))}) burst {burst}")
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
