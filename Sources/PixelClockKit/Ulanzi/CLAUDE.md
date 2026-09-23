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

`pct-*` pages listed in `GET /api/customList` while the app is not running
prove nothing about how it exited: `UlanziClockSession.shutdown` is meant to
delete every page it owns on quit, yet a normal Quit on 2026-09-23 left all
three `pct-*` pages on the clock. Treat quit-time cleanup as unverified.

## Animation budget

- One page plays a GIF by itself; the Mac never rotates or re-pushes for motion.
- GIFs must be FULL frames with one global palette (`FullFrameGif`); a
  cropped-frame GIF smears on the panel.
- Measured on the TC002, 2026-09-23 (the weather face's design, spec §2.1):
  - **One GIF at 478 frames / 135 240 bytes of base64 plays smoothly and on
    time.** `UlanziScene` enforces ≤ 480 frames and ≤ 136 000 bytes; the
    documented 50 frames / 60 KB were never measurements and are wrong here.
  - **Two GIFs on one page drift.** Each plays its own delays, but the panel
    pays a per-frame cost, so a 321-frame GIF falls behind a 36-frame one. Use
    two GIFs only where nothing has to line up.
  - **A Mac re-push is not frame-accurate.** Pushes once per state left on
    time (±80 ms) and the picture still missed; anything that must stay in
    step belongs inside ONE GIF.
  - **What must change with a page must slide with it.** Swapping an icon
    halfway through a slide reads as early, swapping it on landing reads as
    late; only a shared slide reads as right.
- Delay is per frame (centiseconds): a dwell is ONE frame with a long delay,
  never repeated frames. A marquee scrolls only its overflow, 1 px per frame
  (~100 ms reads as smooth); a 2 px step reads as jerky.

## Faces

- Designs are approved in the browser and on the clock first, via the
  `tc002-face-mockup` skill (`.claude/skills/tc002-face-mockup/`). Its `gen.py`
  frames are the pixel oracle for the Swift face — change the design there,
  then the fixture, then Swift.
- Letters on the 52×16 panel are 5 px tall with canonical lowercase shapes; the
  skill's SKILL.md holds the glyph rules.
- Dates are formatted in `TimeZone.current` from absolute `Date`s, whatever
  zone the vendor's server lives in (z.ai's is Asia/Shanghai).
