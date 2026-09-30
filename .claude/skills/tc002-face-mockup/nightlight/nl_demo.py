#!/usr/bin/env python3
"""Live TC002 demo of a night-light scene: ngen's approved frames as one
full-frame GIF, pushed as the DIY page `demo-<scene>` (the running app never
touches a demo-* page) and switched to. It stays until --remove.

  python3 nl_demo.py                         # Red Moon, 100 %, 1×
  python3 nl_demo.py --still 0               # one frame, no motion
  python3 nl_demo.py --level 2 --speed 1/2   # 40 %, half speed
  python3 nl_demo.py --remove
"""
import argparse, base64, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]   # ngen here; gen.py and tc002_demo.py one up
import tc002_demo   # noqa: E402  (the GIF writer and post())
import ngen         # noqa: E402

GIF_B64_LIMIT = 136_000
FRAME_LIMIT = 480
SPEEDS = {"1/2": (1, 2), "1/1": (1, 1), "2/1": (2, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", default="moon")
    ap.add_argument("--level", type=int, choices=range(1, 6), default=5, help="brightness step, 5 = 100 %%")
    ap.add_argument("--speed", choices=SPEEDS, default="1/1")
    ap.add_argument("--still", type=int, metavar="FRAME", help="push this one frame, not the loop")
    ap.add_argument("--page", help="page name suffix, to keep a variant beside the last push")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()
    page = f"demo-{a.page or a.scene}"
    if a.remove:
        print(page, tc002_demo.post(f"/api/custom?name={page}", b""))
        return
    frames = ngen.timeline(a.scene, a.level, SPEEDS[a.speed])
    if a.still is not None:
        frames = [(frames[a.still][0], 1000)]
    data = tc002_demo.gif(frames)
    b64 = base64.b64encode(data).decode()
    print(f"{page}: {len(frames)} frames, loop {sum(ms for _, ms in frames) / 1000:.1f}s, "
          f"level {a.level}, speed {a.speed}, gif {len(data)} B, base64 {len(b64)} B")
    if len(frames) > FRAME_LIMIT or len(b64) > GIF_B64_LIMIT:
        sys.exit(f"over the measured budget ({FRAME_LIMIT} frames / {GIF_B64_LIMIT} B base64) — not pushed")
    envelope = {"duration": 600, "image": [{"data": "data:image/gif;base64," + b64, "position": [0, 0]}]}
    print("custom:", tc002_demo.post(f"/api/custom?name={page}", json.dumps(envelope).encode()))
    print("switch:", tc002_demo.post(f"/api/switchDiyApp?name={page}", b""))


if __name__ == "__main__":
    main()
