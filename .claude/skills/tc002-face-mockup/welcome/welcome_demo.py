#!/usr/bin/env python3
"""Live TC002 demo of the welcome screen: welcome.py's approved frames as one
full-frame GIF, pushed as the DIY page `demo-welcome` (the running app never
touches a demo-* page) and switched to.

  python3 welcome_demo.py            # push and show
  python3 welcome_demo.py --remove   # delete the demo page
"""
import argparse, base64, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]   # welcome.py here; gen.py and tc002_demo.py one up
import gen          # noqa: E402
import tc002_demo   # noqa: E402  (the GIF writer and post())
import welcome      # noqa: E402

PAGE = "demo-welcome"
GIF_B64_LIMIT = 136_000
FRAME_LIMIT = 480


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--hold", action="store_true", help="keep the page (looping) until --remove")
    a = ap.parse_args()
    if a.remove:
        print(PAGE, tc002_demo.post(f"/api/custom?name={PAGE}", b""))
        return
    welcome.VERSION_LOOP = welcome.VERSION_LOOPS[0][2]
    _, _, full, rel = welcome.SPARKS[0]
    frames = welcome.timeline("tc", full, rel, welcome.STARS, welcome.FONT)
    gen.W, gen.H = 52, 16
    data = tc002_demo.gif(frames)
    os.makedirs(welcome.OUT, exist_ok=True)
    open(os.path.join(welcome.OUT, "demo-welcome.gif"), "wb").write(data)
    b64 = base64.b64encode(data).decode()
    print(f"{len(frames)} frames, cycle {sum(ms for _, ms in frames) / 1000:.1f}s, "
          f"gif {len(data)} B, base64 {len(b64)} B")
    if len(frames) > FRAME_LIMIT or len(b64) > GIF_B64_LIMIT:
        sys.exit(f"over the measured budget ({FRAME_LIMIT} frames / {GIF_B64_LIMIT} B base64) — not pushed")
    envelope = {"duration": 600 if a.hold else 10, "image": [{"data": "data:image/gif;base64," + b64, "position": [0, 0]}]}
    print("custom:", tc002_demo.post(f"/api/custom?name={PAGE}", json.dumps(envelope).encode()))
    print("switch:", tc002_demo.post(f"/api/switchDiyApp?name={PAGE}", b""))
    if a.hold:
        print("held: stays on the clock until --remove")
        return
    # Like the feature: the welcome is shown once for 10 s, then taken down.
    time.sleep(welcome.SHOW_MS / 1000 + 0.2)
    print("remove:", tc002_demo.post(f"/api/custom?name={PAGE}", b""))


if __name__ == "__main__":
    main()
