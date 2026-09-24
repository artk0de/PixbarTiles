---
name: tc002-tile-screen
description: Lay out a custom TC002 (52×16) tile screen — canvas zones, which pixel font for which job, colours, fitting text into 34 px, labels/units, missing data, and 16×16 icon rules. Triggers on "new tile", "design a screen for the clock", "какой шрифт на часах", "нарисуй экран плитки", "не влезает текст на часах", "draw an icon for the TC002". Motion (tickers, slides, marquees, GIF timing) is `tc002-ticker-motion`; the mockup → live demo → oracle tooling is `tc002-face-mockup`.
---

# TC002 tile screen

Rules for WHAT goes on a 52×16 page. Every rule here was paid for on the real
panel (usage face 2026-09-2x, weather face 2026-09-23). Design in
`tc002-face-mockup`'s generator first; this skill says what the design must obey.

## Canvas zones

```
x: 0        15 16 17 18                                   51
   ┌─────────┐  gutter ┌──────────────────────────────────┐
   │ icon    │  2 px   │ area 34×16                        │ rows 0–8: hero figure (5×9 digits)
   │ 16×16   │         │                                    │ rows 9–10: breathing space
   │         │         │                                    │ rows 11–15: one 5 px line
   └─────────┘         └──────────────────────────────────┘
```

- **Icon at (0,0), 16×16; area at x=18, 34×16.** Both weather layouts and the
  usage face use this split; a new face needs a reason to break it.
- **Hero figure + one line** is the proven shape: a big value (rows 0–8) and a
  5 px label/ticker line at rows 11–15. Two 5 px lines fit at y=2 and y=9
  (moon page); three 5 px lines do NOT fit 16 rows legibly — rows 6–10 and
  11–15 touch and read as one smear.
- A still line never moves; anything that changes over time has its own row
  band (see `tc002-ticker-motion`).

## Fonts — pick by job

All faces live in `Sources/PixbarKit/Ulanzi/` as `PixelFont.<face>`;
measure with the SAME face you draw with (`PixelFontFace.advance(for:)`).

| Face | Cell | Use for | Never for |
|---|---|---|---|
| `proportional` (`ProportionalGlyphs`, Python `G`) | 5 rows, proportional (`:` `.` space = 1, `w` `m` = 5, `i` = 1, rest 3), gap 1 | every label, value and ticker line on a TC002 face | Cyrillic (has no shapes) |
| `big` (`BigDigitGlyphs`, Python `B`) | 5×9, digits/`%` 5 wide, `-` `°` 3 | the ONE hero figure (temperature, percent) | text |
| `standard` (X11 5×7, generated from BDF) | 5×7 fixed | free text that may be Cyrillic, AWTRIX-style text | mixing with 5-row text on one line |
| `tiny` (3×5) | 3×5 fixed, 4-row lowercase | legacy fallback only | new faces — a 4-row letter beside a 5-row digit reads as broken |

Glyph rules (learnt on the panel):

- **All letters 5 px tall.** Canonical shapes: `e` with bowl, crossbar and open
  tail; two-storey `a`; `j` with its dot; `g` with a descender. A box-shaped
  letter reads as a digit.
- A glyph the face lacks draws the substitute `?` — so a new word may need a
  new glyph (`q` was added for `quarter`). Add it in the Python table first,
  then the Swift table, held equal by the glyph oracle test.
- Width of a string = Σ(glyph widths) + (n−1) gaps. Compute it in the
  generator (`wgen.width`) for the WORST case before approving a string.

## Fitting 34 px

The area is 34 columns. Plan every string at its widest value:

- Budget examples (measured with `wgen.width` / `parts_width`): `crescent` =
  31, `quarter` = 27, `waxing` = 23, `new moon` = 33 (the space is 1 px),
  `moon 100%` = 35 with the 3 px label gap — does NOT fit, `lit 100%` = 27.
  Never estimate by character count; measure.
- Fallback order when a line is too wide: drop decoration first (degree signs
  before values), then shorten the word (a noun instead of two words), never
  clip. Decide the fallback in the generator, per value, not per locale guess.
- Two words that cannot share one line become a two-line page, not a
  scrolling line — scrolling is for values that change (resets), not names.
- Exception: a name the app does not choose and cannot bound — a GitHub repo
  name — scrolls its overflow as an edge marquee when it does not fit, and a
  user-set short name stays an optional override (the user's call,
  2026-09-23). A name the face itself picks (a moon phase, a label) still has
  to fit.

## Labels, values, units

- **Label/value gap:** 3 px after a grey word label, 2 px after a value, 1 px
  after an arrow/mark. Tighter and `h 64%` reads as one word; ≥ 4 px between a
  label and a SCROLLING value.
- **Labels grey `#606060`, values coloured, absent/dim `#404040`.** A
  one-letter label must be grey or it reads as a digit (`g` for gusts read as
  `9` when coloured).
- **A temperature always names its scale** (`c`/`f`), on every page that shows
  one — the user caught a feels page without it.
- Colour carries meaning only together with shape or text: the panel is dim
  and hue-only warnings vanish. 1 px bars read fine.
- Colours in use: temperature ramp (`TemperatureColour`, −20…+35 °C stops),
  humidity/rain `#4DA6FF`, rain cap on blue bars `#D8F0FF` (a blue cap on a
  blue bar is invisible), sun `#FFB52E`, moon `#F4EBB8`, white `#E8E8E8`,
  track `#303030`, vendor brand colours from the connector.

## Missing data

- A detail whose data is missing is **absent** (the line or page drops out of
  the rotation), never a placeholder dash — except the whole-reading case,
  which is ONE `no data` page/line in dim grey with the `nodata` icon.
- A partial block (hi/lo missing on a page that has a temperature) leaves its
  row blank rather than half-filled.

## Icons (16×16)

- Animate continuously while shown — the user rejected icons that freeze
  after a burst. Motion budget rules are in `tc002-ticker-motion`.
- Design at LED scale, not vector scale: a radius-3 circle reads square — use
  3.5; an outline-only drop reads as a bag — fill the empty part with a dark
  tint (`#0E2A4A`); thin streaks need full brightness heads (`#F2FAFF`) with a
  dim tail; a "frosty clear" sun needs pale rays or it reads as a moon.
- Every WMO state gets its own icon (46 + `nodata` in `weather/icons.py`); a
  generic icon for a specific condition is the first thing a user notices.
- Check an icon on the contact sheet (`weather/sheet.py`, Read the PNG) and
  then live — the sheet shows shape, only the panel shows brightness.

## Before you call a screen done

1. Worst-case width computed for every string and every fallback.
2. Every data-missing combination rendered as a case.
3. Key frames Read as PNG by you, then shown to the user, then pushed live.
4. The user looked at the panel — a 200 from the clock proves nothing
   (`Sources/PixbarKit/Ulanzi/CLAUDE.md`).
