---
name: tc002-face-mockup
description: Design a TC002 (52×16) or AWTRIX pixel-clock face as a browser mockup before writing Swift — every corner case rendered as LED dots, animations (reset flips, marquees) played in a self-contained index.html, then pushed live to the clock for sign-off. Triggers on "design a tile face", "mockup the clock screen", "нарисуй дизайн плитки", "покажи в браузере", "сгенерируй картинки для часов", "demo on the clock". NOT for changing an already-approved face's Swift code — edit the kit directly for that.
---

# TC002 face mockup

A face is approved in the browser and on the real clock BEFORE any Swift is
written. The pipeline has one source of pixels:

```
gen.py  ──►  timeline per case: [(52×16 canvas, duration_ms)]
   │           ├─► tc002-mockup-out/index.html   (frames embedded; template.html only PLAYS them)
   │           ├─► tc002-mockup-out/*.png         (key frames, for a look without a browser)
   └─► tc002_demo.py ──► full-frame GIF89a, per-frame delays ──► POST /api/custom on the clock
```

Because the browser and the clock both consume `gen.py`'s frames, what the
user approves in the HTML is byte-for-byte what the clock shows — and the same
frames are the pixel oracle the Swift face is tested against.

## Workflow

1. **Copy, don't edit in place.** Work in the job's tmp dir or a scratch dir;
   this directory holds the approved usage face as the worked example.
   ```bash
   cp .claude/skills/tc002-face-mockup/{gen.py,template.html,tc002_demo.py} <scratch>/
   ```
2. **Describe the face in `gen.py`**: `VENDORS` (logo bitmap + colours), `G`
   (glyphs), the layout constants, `draw()` and `timeline()`, and `CASES` —
   one entry per corner case (steady, each warning band, both hot, spent/cap,
   zero, no data, partial data, worst-case width, every tile-parameter effect).
3. **Render and open**: `python3 gen.py && open tc002-mockup-out/index.html`.
   Look at the key-frame PNGs yourself (Read them) before showing the user —
   check clipping, glyph collisions, width at the worst case.
4. **Iterate with the user** on the HTML. Tile parameters (intervals,
   thresholds) belong in the page as live `<select>`s; precompute one
   timeline per value in `gen.py` rather than re-implementing drawing in JS.
5. **Live demo**: `TC002_HOST=<ip> python3 tc002_demo.py` pushes demo pages
   under their own names (`demo-*`), so the running app never overwrites them,
   and switches the clock to one. `--remove` deletes them afterwards.
6. After sign-off, implement in the kit with the approved frames as the test
   oracle (render a case in Swift, compare pixels to `gen.py`'s).

## Hardware facts the generator already obeys

| Fact | Consequence |
|---|---|
| Panel 52×16; brightness is low | 1 px bars read fine; hue-only warnings do not |
| `image[]` GIF: ≤ 50 frames, base64 ≤ 60 KB (documented) | marquees scroll only the overflow (`marquee="edge"`), 1 px/step |
| GIFs must carry FULL frames, one global palette | the writer in `tc002_demo.py` never crops |
| GIF delay is per frame (centiseconds) | dwell phases are ONE frame with a long delay, not repeats |
| `draw[].db` is `[x, y, w, h, [pixels]]` | the flat `[w, h, …]` spelling renders black (measured 2026-09-23) |
| `switchDiyApp` is POST-only | GET answers 404 |

## Glyph rules learnt the hard way

- All letters 5 px tall — 4 px lowercase next to 5 px digits reads as broken.
- Canonical lowercase shapes: `e` has a bowl, a crossbar and an open tail;
  `a` is two-storey; `j` has its dot; `g` has a descender. A box-shaped letter
  reads as a digit.
- `:` `.` and space are 1 px wide; `w` and `m` are 5 px wide.
- Leave ≥ 4 px between a label and a scrolling value, or the two read as one word.
- Dates on the panel are always in the Mac's `TimeZone.current`, whatever zone
  the vendor's server lives in.
