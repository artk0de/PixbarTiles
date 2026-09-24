#!/usr/bin/env python3
"""Side-by-side calibration on the TC002: candidates drawn in one labelled
52x16 frame, pushed under a demo page so the user can pick one on the panel.

  # colours: the same sample in each candidate colour
  python3 calibrate.py colours '#FFD84A' '#F2E04A' '#FFE680' --sample '★' --font big

  # glyph shapes: each candidate glyph before the same text, in one colour
  python3 calibrate.py glyphs '.###.,.###.,.....,#####,#####' '.#.,###,.#.,.#.,#.#' \\
      --text bob --colour '#909090'

  # anything else: a JSON list of cells, each a label and its parts
  python3 calibrate.py spec cells.json
  #   [{"label": "a", "parts": [{"text": "12", "colour": "#FFD84A", "font": "big"}]}, ...]
  #   a part may carry "glyph": ["rows", ...] to define its one-character text

  --dry-run   render the PNG (calibrate.png beside this script) and push nothing
  --remove    delete the demo page
  --page      demo page name (default demo-calibrate; never a pbt-* or pct-* name)

Glyph tables are the faces' own (github/ggen.py extends weather/wgen.py), so a
candidate that wins here is drawn exactly the same once it moves into a face.
"""
import argparse, base64, json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tc002-face-mockup", "github"))
import ggen  # noqa: E402

HOST = os.environ.get("TC002_HOST", "192.168.1.72")
W, H = ggen.W, ggen.H
LABELS = "abcdefghij"
FONTS = {"small": ggen.G, "big": ggen.B}
LABEL_GAP = 1


def post(path, body):
    req = urllib.request.Request(f"http://{HOST}{path}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def cell_width(cell):
    w = ggen.width(cell["label"]) + LABEL_GAP + 1
    for i, p in enumerate(cell["parts"]):
        w += ggen.width(p["text"], FONTS[p.get("font", "small")]) + (1 if i < len(cell["parts"]) - 1 else 0)
    return w


def cell_height(cell):
    return max(len(FONTS[p.get("font", "small")][p["text"][0]]) for p in cell["parts"]) if cell["parts"] else 5


def render(cells):
    """Cells left to right, wrapping into as many rows as fit; the label in
    grey sits at the top of its cell."""
    for c in cells:
        for p in c["parts"]:
            if "glyph" in p:
                FONTS[p.get("font", "small")][p["text"]] = p["glyph"]
    a = ggen.Area(W, H)
    x, y, row_h = 0, 0, 0
    for c in cells:
        cw, ch = cell_width(c), cell_height(c)
        if x and x + cw > W:
            x, y, row_h = 0, y + row_h + 1, 0
        if y + ch > H:
            raise SystemExit(f"cell {c['label']} does not fit the panel — fewer candidates per push")
        cx = a.text(c["label"], x, y, ggen.LABEL, ggen.G) + LABEL_GAP
        for p in c["parts"]:
            cx = a.text(p["text"], cx, y, ggen.hexrgb(p["colour"]), FONTS[p.get("font", "small")]) + 1
        x += cw + 3
        row_h = max(row_h, ch)
    return a.px


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", nargs="?", choices=["colours", "glyphs", "spec"])
    ap.add_argument("items", nargs="*")
    ap.add_argument("--sample", default="12", help="colours: what to draw")
    ap.add_argument("--font", default="small", choices=list(FONTS))
    ap.add_argument("--text", default="", help="glyphs: text after each glyph")
    ap.add_argument("--colour", default="#E8E8E8", help="glyphs: glyph colour")
    ap.add_argument("--page", default="demo-calibrate")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()
    if not a.page.startswith("demo-"):
        raise SystemExit("calibration pages are demo-* — pbt-* (and legacy pct-*) belong to the app")
    if a.remove:
        print(a.page, post(f"/api/custom?name={a.page}", b""))
        return
    if a.mode == "colours":
        cells = [{"label": LABELS[i], "parts": [{"text": a.sample, "colour": c, "font": a.font}]}
                 for i, c in enumerate(a.items)]
    elif a.mode == "glyphs":
        cells = []
        for i, rows in enumerate(a.items):
            # One private-use character per candidate: they all live in the
            # same font table while the frame is drawn.
            parts = [{"text": chr(0xE000 + i), "colour": a.colour, "glyph": rows.split(",")}]
            if a.text:
                parts.append({"text": a.text, "colour": "#E8E8E8"})
            cells.append({"label": LABELS[i], "parts": parts})
    elif a.mode == "spec":
        cells = json.load(open(a.items[0], encoding="utf-8"))
    else:
        raise SystemExit("mode: colours | glyphs | spec")
    grid = render(cells)
    ggen.sheet.png(grid, os.path.join(HERE, "calibrate.png"))
    if a.dry_run:
        print("rendered", os.path.join(HERE, "calibrate.png"))
        return
    gif = ggen.wgen.gif([(grid, 1000)], W, H)
    env = {"duration": 30, "image": [{"data": "data:image/gif;base64," + base64.b64encode(gif).decode(),
                                      "position": [0, 0]}]}
    print("custom:", post(f"/api/custom?name={a.page}", json.dumps(env).encode()))
    print("switch:", post(f"/api/switchDiyApp?name={a.page}", b""))


if __name__ == "__main__":
    main()
