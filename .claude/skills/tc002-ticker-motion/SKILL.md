---
name: tc002-ticker-motion
description: Make things move on a TC002 (52×16) tile — rotating ticker lines, sliding pages, marquees for text that does not fit, animated icons beside changing text — as ONE GIF timeline the panel plays itself, inside the measured frame/byte budget. Triggers on "бегущая строка", "ticker", "marquee", "менять данные каждые N секунд", "анимация не в такт", "иконка запаздывает", "тормозит на часах", "GIF too big for the clock". Static layout and fonts are `tc002-tile-screen`; the mockup/demo tooling is `tc002-face-mockup`.
---

# TC002 ticker and motion

The TC002 plays a GIF by itself; the Mac pushes a page once per data change and
never re-pushes for motion. Everything below was measured on the panel with a
human watching (2026-09-23) — there is no readback, so the eye is the oracle.

## The one rule: what must stay in step lives in ONE GIF

| Tried | What the user saw |
|---|---|
| Two GIFs on one page (icon GIF + text GIF), each with its own delays | drift: the panel pays a per-frame cost, a long GIF falls behind a short one — "иконка не в такт" |
| Two GIFs cut at identical frame boundaries (lockstep) | in step, but twice the frames — "в такт, но тормозит" |
| Mac re-pushes the page once per state | pushes left on time (±80 ms), the picture still missed — "не в такт" |
| ONE 52×16 GIF holding icon and text | in step, smooth — approved |

So: two GIFs only where nothing has to line up (Anchor: an icon that never
changes with the ticker, beside a text GIF). Anything else is one full-panel
timeline.

## Slides: whatever changes with a page moves with it

- Swapping the icon halfway through a text slide reads as **early**; swapping
  it on landing reads as **late**. Only a shared slide reads as right.
- **Ticker (Anchor/Hybrid):** the 5 px line at rows 11–15 slides up 1 row per
  step, 60 ms a step, over a 6-row pitch (5 rows + 1 blank) — `STEP_MS = 60`,
  `SLIDE = 6`. The hero figure above never moves.
- **Hybrid:** the icon slides 3 rows per step over the SAME steps
  (`ICON_STEP = 3`), so icon and line land together.
- **Pages:** the whole panel — icon and figure — slides up 2 rows per step,
  40 ms a step, 8 steps (`PAGE_STEP_MS = 40`, `PAGE_STEPS = 8`).
- Step durations are chosen as whole centiseconds (GIF delays are integer
  cs): 60 and 40 ms are exact; 50/33 ms rounded and accumulated visible drift.
- Default dwell ("Change every") is 10 s — the user's call; 3/5/8/10/15 s offered.

## Marquees: only for a value that does not fit

- Scroll only the **overflow**, 1 px per frame at ~100 ms (edge marquee:
  `EDGE_STEP_MS = 100`), holding 1 s at the start and 1.5 s at the end so both
  ends are readable. 2 px steps read as jerky; a full-width marquee (60 ms,
  entering right, leaving left) is for long free text only.
- Names and labels do not scroll — make them fit (`tc002-tile-screen`), except
  an unbounded external name (a repo name), which edge-marquees its overflow.
- A marquee longer than its dwell stretches the dwell: the pass always
  finishes, so the start and the end are both read.

## Timeline construction

- A dwell is ONE frame with a long delay, never repeated frames.
- An animated icon beside a still page: expand the icon's own loop across the
  dwell (`wgen.play`) — whole loops, then the remainder; a sub-20 ms leftover
  merges into the previous frame instead of becoming a frame.
- A single state (only one detail enabled): Hybrid/Pages play one whole icon
  loop as the GIF; Anchor's area is one still 1000 ms frame.
- GIF frames are FULL 52×16 frames with one global palette (`FullFrameGif`);
  cropped sub-rectangles smear on the panel.

## Budget

- Measured ceiling: **≤ 480 frames and ≤ 136 000 bytes of base64 per GIF**
  (478 frames / 135 240 bytes played smoothly). The documented 50 frames /
  60 KB are wrong for this panel. `UlanziScene` enforces the measured numbers.
- Over budget, fall back to **burst**: after each change the icon plays whole
  loops for ≥ 2 s (`BURST_MS`), then rests on its first frame for the dwell.
  Burst is the fallback only — by default icons animate the whole dwell.
- The early "тормозит" reports were lag from two drifting GIFs, not a frame
  ceiling; do not cut frames to fix a sync complaint.

## Verifying motion

1. Push the candidate under a demo name (`demo-*`, never `pct-*`) with the
   face's demo script and switch the clock to it.
2. Ask ONE question about ONE thing: in step or not; smooth or not; which leads.
   "Что именно тормозит?" separated lag ("смена иконки запаздывает") from speed.
3. Change one variable per push (layout, mode, interval) — the differential is
   the only reliable diagnosis on a panel you cannot read back.
4. Remove the demo page afterwards (`--remove`); the clock answers 200 either
   way, so confirm with the user that it is gone.
