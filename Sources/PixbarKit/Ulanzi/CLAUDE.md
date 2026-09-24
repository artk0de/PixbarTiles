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
   (POST only — GET is 404). Never reuse a `pbt-*` (or legacy `pct-*`) name: the app owns those and
   overwrites them.
2. Change ONE thing between two probes (the differential) and ask a human what
   the panel shows. That is the only oracle.
3. Delete probes with an EMPTY-body POST to the same name (a `{}` body keeps the
   page in the knob cycle — `UlanziDevice.removeApp`).

`pbt-*` pages stay on the clock after a Quit, by design: the app quits with
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

## Page order

- DIY pages run in the order they were CREATED. There is no order or
  position API. Measured on appVer 1.1.1, 2026-09-24, with three 1-frame
  probes (removed right after): `probe-order-b`, `-a`, `-c` pushed in that
  order listed `b, a, c` in `customList` (not sorted). An upsert of `b` kept
  its place. `b` deleted (empty-body POST) and pushed again moved to the END.
  That `customList` order is also the knob order is inferred, not observed on
  the panel.
- So the app's tile order (the tiles record, dragged in Clock Settings →
  Tiles) is kept by re-creation: `UlanziClockSession.arrange(order:)` compares
  our pages in `customList` order with the app's order and re-creates (delete +
  push) from the first one out of place onwards. Pages already in order cost
  nothing beyond the list read the 60 s check already makes. It runs from that
  check (`UlanziClockHost.verifyPages`) and right after a drag
  (`AppModel.moveTile` → `UlanziPageOrdering.pagesReordered`).
- Only pages whose content the session knows (`onDevice`) are re-created, with
  exactly that frame. Nothing moves while an interruption window is open, and
  an outage stops the run. The recovery sweep re-pushes in the app's order, so
  pages a reboot lost come back in order too.

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

## Device load budget

The TC002 froze and then rebooted under this app's load (2026-09-24). Every
upsert makes it decode and replace a whole page, so the budget is counted in
upserts and in bytes, not in requests alone. The user's setup is 4 pages:
GitHub every 60 s, z.ai 600 s, weather 600 s, Claude 900 s.

| Per minute, steady state | Before | Now |
|---|---|---|
| HTTP requests | ~2.3: `/getBase` 1, GitHub 1, others ≤ 0.27 | ~2.3: `/getBase` 1, `customList` 1, others ≤ 0.27 |
| Upserts (page decodes) | ~1.27 | ≤ 0.27 |
| Bytes to the clock | ~85–90 KB (GitHub's 73–92 KB GIF = 93–96%) | ~4–7 KB typical, ≤ ~36 KB worst case |
| ADB streams (battery) | 9, plus a `cat` fork per process (~50–150 forks) | 3, no /proc sweep |

- "Others" means z.ai, weather and Claude, counted as changing on every tick
  (0.1 + 0.1 + 0.067 upserts/min). The typical figure comes from their share
  of the pre-fix traffic (4–7%). The worst case assumes all three at the
  136 000-byte ceiling. Any of them left unchanged costs nothing now.
- GitHub pushes only when its page changes. A star with Celebrate on all app
  pages on costs one forced ambient push, 4 celebration pushes and 4 restores.
- These are the arithmetic of the send paths, not a measurement on the
  panel. Re-derive them when a cadence, the poll or the battery read changes.
- What keeps the budget: `UlanziClockSession` skips a byte-identical upsert
  (`onDevice`), only a transport failure owes a sweep, a sweep runs one at a
  time with 60/120/300 s backoff, and `UlanziBattery` keeps the zkgui
  pid/base/monitor between reads.
- A reboot is found by the 60 s health poll, not by pushing. The poll sees
  the clock come back from unreachable, sees a new zkgui pid, or reads
  `customList` without one of our pages (`UlanziClockSession.clockReturned`
  / `verifyPages`). Only the lost pages are re-pushed.

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
