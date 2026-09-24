# Ulanzi (TC002) — navigator

Local knowledge for editing the TC002 adapter: what the clock actually does on
the wire, as opposed to what its documentation says. Cite code by symbol, never
by line. The research history lives in
`docs/superpowers/research/2026-09-18-tc002-screens-and-sound.md` and
`docs/HANDOFF.md`; this file keeps only what bites when you edit here.

## The clock answers 200 and draws black

The TC002 (appVer 1.1.1) validates nothing it cannot render. A malformed
`draw[]` / `text[]` / `image[]` entry is accepted with
`{"code":200,"message":"ok"}` and the page goes black. A green suite and a 200
prove nothing about the pixels — only a look at the panel does.

- **`db` is `[x, y, w, h, [pixels]]`** — position first, pixels NESTED. The flat
  `[w, h, p0, p1, …]` spelling renders black. Measured 2026-09-23 by pushing the
  same 52×16 frame both ways; the flat spelling is why every TC002 tile was
  black until `UlanziDraw.bitmap`'s encoder was fixed.
- `text[]` entries must be objects; a bare string renders black (HANDOFF §6f).
- `image[]` entries must be `{"data": "data:image/gif;base64,…", "position": [x, y]}`.

## There is no readback

`/api/screen` (the AWTRIX matrix readback) answers 301 on the TC002, and the
app's `Logger` output is info-level, which macOS does not persist. To diagnose
a black or wrong page:

1. Push a known-good frame to a PROBE page under its own name
   (`POST /api/custom?name=probe-…`), then `POST /api/switchDiyApp?name=probe-…`
   (POST only — GET is 404). Never reuse a `pct-*` name: the app owns those and
   overwrites them.
2. Change ONE thing between two probes (the differential) and ask a human what
   the panel shows. That is the only oracle.
3. Delete probes with an EMPTY-body POST to the same name (a `{}` body keeps the
   page in the knob cycle — `UlanziDevice.removeApp`).

`pct-*` pages stay on the clock after a Quit, by design: the app quits with
`.terminateNow` (`AppDelegate.applicationShouldTerminate`, the user's call of
2026-09-21 — a teardown wait against an unreachable clock made the panel read
as broken), so `UlanziClockSession.shutdown` never runs on Quit. Leftovers are
cleared at the next launch by `UlanziCustody.sweep(liveTiles:)` (the user chose
launch-time cleanup over a bounded quit delay, 2026-09-23). `shutdown` still
runs when a clock is removed in the app.

## Page switching

- `GET /api/customList` answers BARE: `{"apps":[…],"count":N}` — no `code`,
  no `data` (measured 2026-09-24). `UlanziDevice.customApps` reads it
  without demanding the envelope.
- The app switches a page in exactly one place: the user opening a tile's
  settings (`AppModel.openDetail` → `UlanziDevice.switchToApp`). Every
  schedule and event path stays unswitched (D3 — a switch drops an open
  tool to DIY L2).
- The firmware cannot say which page is on screen, so closing the window
  leaves the clock on the tile's page — there is nothing known to go back
  to. The AWTRIX reads `app` from `/api/stats` and does go back.

## Animation budget

- One page plays a GIF by itself; the Mac never rotates or re-pushes for motion.
- GIFs must be FULL frames with one global palette (`FullFrameGif`); a
  cropped-frame GIF smears on the panel.
- `UlanziScene` enforces the MEASURED ceiling — ≤ 480 frames, ≤ 136 000 bytes
  of base64 (2026-09-23); the documented 50 frames / 60 KB are wrong here. Do
  not lower it to "be safe": the weather face ships 478-frame GIFs.
- Anything that must stay in step belongs inside ONE GIF — two GIFs on a page
  drift and a Mac re-push is not frame-accurate. The measurements, slide
  constants and marquee timing are owned by the `tc002-ticker-motion` skill.

## Faces

- Designs are approved in the browser and on the clock first, via the
  `tc002-face-mockup` skill (`.claude/skills/tc002-face-mockup/`). Its `gen.py`
  frames are the pixel oracle for the Swift face — change the design there,
  then the fixture, then Swift.
- Which `PixelFont` face draws what (proportional for text, `big` for the one
  hero figure, `standard` only for Cyrillic), the 34 px fitting rules and the
  glyph shapes are owned by the `tc002-tile-screen` skill. Every table here is
  a copy of a Python oracle table — add a glyph there first.
- Dates are formatted in `TimeZone.current` from absolute `Date`s, whatever
  zone the vendor's server lives in (z.ai's is Asia/Shanghai).
