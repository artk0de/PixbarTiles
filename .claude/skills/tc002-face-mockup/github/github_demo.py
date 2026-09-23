#!/usr/bin/env python3
"""Live TC002 demo of the GitHub face.

Frames come from ggen.py — the code the HTML mockup plays and the Swift face's
oracle records. This file only picks a case, encodes ONE 52x16 GIF and pushes
it under its own page name, so the running app never overwrites it.

  python3 github_demo.py                    # a1-steady, ticker every 10 s
  python3 github_demo.py --case c2          # any case id prefix from ggen.CASES
  python3 github_demo.py --interval 5       # ambient: seconds per ticker line
  python3 github_demo.py --celebrate 10     # celebration: seconds it lasts (loops here)
  python3 github_demo.py --remove
"""
import argparse, base64, json, os, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ggen  # noqa: E402

HOST = os.environ.get("TC002_HOST", "192.168.1.72")
PAGE = "demo-github"


def post(path, body):
    req = urllib.request.Request(f"http://{HOST}{path}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", default="a1")
    ap.add_argument("--interval", type=float, default=10)
    ap.add_argument("--celebrate", type=float, default=8)
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()
    if a.remove:
        print(PAGE, post(f"/api/custom?name={PAGE}", b""))
        return
    case = next(c for c in ggen.CASES if c["id"].startswith(a.case))
    frames = ggen.build(case, dwell=int(a.interval * 1000), celebrate=int(a.celebrate * 1000))
    g = ggen.wgen.gif(frames, ggen.W, ggen.H)
    b64 = base64.b64encode(g).decode()
    print(f"{case['id']}: {len(frames)} frames, {len(g)} B (base64 {len(b64)}), fits={ggen.fits(frames)}")
    env = {"duration": 30, "image": [{"data": "data:image/gif;base64," + b64, "position": [0, 0]}]}
    print("  custom:", post(f"/api/custom?name={PAGE}", json.dumps(env).encode()))
    print("  switch:", post(f"/api/switchDiyApp?name={PAGE}", b""))


if __name__ == "__main__":
    main()
