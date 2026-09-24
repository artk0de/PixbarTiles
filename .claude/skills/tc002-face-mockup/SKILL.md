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
   check clipping, glyph collisions, width at the worst case. The PNGs are
   YOUR check only; they are never what the user reviews.

   **HTML review is a MANDATORY GATE.** Open the page in the same turn the
   render finishes, tell the user it is open and what to look at (which cases,
   which controls), and STOP until they answer. Every later render the user is
   meant to see is re-opened the same way. Nothing moves past this step — not
   the next design iteration you would like to try, not the live demo, not a
   line of Swift — without the user's verdict on the HTML.
4. **Iterate with the user IN THE BROWSER until the arrangement is settled.**
   Tile parameters (intervals, thresholds) belong in the page as live
   `<select>`s; precompute one timeline per value in `gen.py` rather than
   re-implementing drawing in JS.

   **The mockup MOVES.** Every dwell, flip, marquee, pulse and transition
   between cards plays in the page, at the delays the clock will use — that is
   what a timeline of `(canvas, ms)` is for, and `index.html` only has to play
   it. A grid of still frames is not a mockup of this face: half of what is
   being judged is timing. Does the eye finish the reset before it slides? Does
   the pulse read as urgent or as a fault? Is the cut jarring where a push
   would say which way the list runs? None of that is visible in a PNG. Render
   the stills for YOURSELF, to catch clipping and collisions before showing;
   render motion for the user.

   Draw what does NOT exist yet. A candidate already implemented in the kit
   costs a round trip to show back — check what the tile draws today before
   deciding what to render, and put the effort into the arrangements nobody
   has seen. Showing the existing one beside the new ones as a reference is
   fine; shipping it AS a candidate is not.
5. **Only after the browser has settled the arrangement, go to the clock.**
   `TC002_HOST=<ip> python3 tc002_demo.py` pushes demo pages under their own
   names (`demo-*`), so the running app never overwrites them, and switches
   the clock to one.

   Never in the same breath as first showing the HTML. The browser is the
   cheap loop — a re-render is seconds and the user can scroll every case at
   once; the clock shows one page at a time and has to be cleaned up after.
   Layout, spacing, clipping and wording are settled in the browser. What the
   clock is FOR is the judgement a monitor cannot make: colour, brightness,
   rhythm, contrast. The LEDs run dim, the dots are round and separated, and a
   deep red that reads as urgent in a browser can be the faintest thing on the
   row at brightness two. Push one page per candidate, mark each with its own
   letter or digit in a free patch of the face, and show every candidate
   beside the state below it — a spent colour is only ever read next to the
   step before it.
6. **Clear the clock the moment the choice is made.** `--remove` every `demo-*`
   page you pushed, before writing any Swift. A demo left behind keeps showing
   invented numbers under the app's own name — a full bar at 104% that nothing
   in the user's account justifies — and the next thing reported is a bug in
   the app that is really a leftover page of yours.
7. After sign-off, implement in the kit with the approved frames as the test
   oracle (render a case in Swift, compare pixels to `gen.py`'s).

## The weather face

The approved TC002 weather face lives in `weather/` and follows the same
pipeline, with its own files:

| File | Role |
|---|---|
| `weather/wgen.py` | The face: layouts, detail lines, transitions, `CASES`, the budget rule |
| `weather/icons.py` | The 46 animated 16×16 icons and `nodata` |
| `weather/wtemplate.html`, `weather/sheet.py` | Browser mockup and icon sheet |
| `weather/weather_demo.py` | Live push to the clock (page `demo-weather`) |

Live demo: `TC002_HOST=<ip> python3 weather/weather_demo.py [flags]`.

- `--layout anchor|pages|hybrid` (default `anchor`);
- `--mode layered|single|lockstep` — `layered` is two GIFs (icon + area),
  `single` one 52×16 GIF, `lockstep` two GIFs cut at the same frame
  boundaries (an experiment in keeping two GIFs in step); the default is `layered`,
  and `single` for Pages;
- `--items feels,humidity,…` — which detail lines rotate, in the spec's order;
  `moon` is the tile's **Moon phase** setting (`showsMoon`, off by default):
  it adds the moon line (Anchor/Hybrid) or page (Pages), and makes a clear
  night the moon in its phase instead of `clearNight` — e.g.
  `--scenario 20 --items feels,moon --layout pages`;
- `--interval <s>` — seconds per state (the tile's "Change every");
- `--burst <ms>` — Pages/Hybrid: icon motion after each change, then rest
  (0 loops the icons through every dwell);
- `--remove` — delete the demo page.

The Swift face (`Sources/PixbarKit/Weather/`) is held to wgen's frames
pixel for pixel and delay for delay. A design change starts in `wgen.py` /
`icons.py`; then re-record the fixtures from the repository root with
`python3 Scripts/make_weather_face_oracle.py`, then change Swift. Never edit
`weather_icons_oracle.json` or `weather_face_oracle.json` by hand.

## Hardware facts the generator already obeys

| Fact | Consequence |
|---|---|
| Panel 52×16; brightness is low | 1 px bars read fine; hue-only warnings do not |
| `image[]` GIF: ≤ 480 frames, base64 ≤ 136 000 bytes (measured 2026-09-23: 478 frames / 135 240 bytes played on time; the documented 50 frames / 60 KB are wrong for this panel) | marquees scroll only the overflow (`marquee="edge"`), 1 px/step; over budget, icons burst then rest (`--burst`) |
| GIFs must carry FULL frames, one global palette | the writer in `tc002_demo.py` never crops |
| GIF delay is per frame (centiseconds) | dwell phases are ONE frame with a long delay, not repeats |
| `draw[].db` is `[x, y, w, h, [pixels]]` | the flat `[w, h, …]` spelling renders black (measured 2026-09-23) |
| `switchDiyApp` is POST-only | GET answers 404 |

## Related skills

- `tc002-tile-screen` — what a screen must obey: zones, fonts, colours, fitting
  34 px, labels and units, missing data, icon drawing.
- `tc002-ticker-motion` — tickers, slides, marquees, one-GIF sync, budget.
- `tc002-calibrate` — when a colour or a small shape is the question, push the
  candidates side by side on the clock and let the user pick by letter.
- `Sources/PixbarKit/Ulanzi/CLAUDE.md` — wire facts (black pages, probes).
