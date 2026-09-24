# PixbarTiles brand: app icon and menu bar glyph

Approved in the browser on 2026-09-24. The two pages next to this file are the
pixel oracles; every number below is read off them.

| Artifact | Oracle page | Status |
|---|---|---|
| Wordmark (`PIXBAR` drawn, `Tiles` lifted 1.5 px) | shipped in `43c029c` | done |
| App icon (colour) | `pixbar-brand/app-icon.html` | approved, to implement |
| Menu bar glyph (monochrome + red) | `pixbar-brand/menu-bar-glyph.html` | approved, to implement |

The app icon and the menu bar glyph are different drawings sharing one idea: a
pixel **P** on a screen. The app icon never appears inside the menu bar glyph.

## The shared P

`P_APP`, 7 columns × 9 rows, stem 3 columns, bowl 6 rows, counter 2 × 2 at
columns 3–4 / rows 2–3, the bowl's two right corners (column 6, rows 0 and 5)
cut:

```
######.
#######
###..##
###..##
#######
######.
###....
###....
###....
```

## App icon

Drawn on a square canvas of `size` px (1024 for the master; the page previews
128/64/32 and a lockup).

- Plate: `#141417`, inset `round(size × 0.08)` on every side, corner radius
  `size × 0.225`.
- LED grid: 17 × 17 cells, `cell = floor(size × 0.84 / 17)`, grid centred
  (`ox = oy = round((size − 17·cell) / 2)`). Every cell is a round dot of
  radius `cell × 0.42` at the cell centre. Unlit dots: white at 6 % alpha.
- P: `P_APP`, lit cells coloured by row — rows 0–2 blue `#4fb8f5`, rows 3–5
  white `#eef0f4`, rows 6–8 purple `#b65cf5`.
- Sparkle: an open plus, cyan `#63d1ff`. On a 7 × 7 half-cell grid, the plus
  of arm width 3 (rows/cols 2–4) is reduced to its outline, and the four arm
  tips (row 0 col 3, row 6 col 3, col 0 row 3, col 6 row 3) are removed so the
  arms stay open. Each outline cell is a square of `1.35 × cell/2` (the "bold"
  weight), centred in its half-cell, pixel-rounded.
- Placement (grid cells): the P + sparkle pair is `7 + 1 + 4 = 12` wide and
  `9 + 2 = 11` tall. `gx0 = floor((17 − 12) / 2) + 1 = 3` (the +1 shift),
  `gy0 = floor((17 − 11) / 2) = 3`. P row `y` sits at grid row `gy0 + 1 + y`
  (lifted one row from `gy0 + 2`). The sparkle's top-left is at grid column
  `gx0 + 8`, grid row `gy0`.

## Menu bar glyph

All sizes in points; @2x means 1 pt = 2 device px. Draw with vector paths
(CoreGraphics), never pixel-scaled bitmaps, so @1x/@2x/@3x all come from the
same geometry.

- Canvas: 28 × 18 pt. Origin shifted by (1, 0.5) pt; coordinates below are
  after the shift.
- Case: 26 × 15 pt, stroke 1.5 pt, drawn on the path inset by 0.75 pt. The
  corners are a pixel staircase of 2 steps of 1 pt each (not rounded), miter
  joins.
- Feet: two 2.5 × 1.5 pt rectangles, square corners, top edge at y = 14.5,
  x = 3.75 and x = 19.75.
- P: `P_APP` at 1 pt per cell, no gap, top-left at (9.5, 3).

States:

| State | Drawing |
|---|---|
| online (a clock is connected) | Case **filled** out to the stroke's outer edge (fill + stroke, 0...26 × 0...15), the same outline the offline state draws — the approved page filled the centreline only, and the glyph shrank by half a stroke when a clock came back (corrected 2026-09-24). The P's cells and a 0.5-pt bezel ring (`strokeRect(2.25, 2.25, 21.5, 10.5)`, width 0.5) are knocked out to transparent. |
| offline (clocks configured, none reachable) | Case **stroked**. The P as a contour: its silhouette rasterised on a 0.5-pt grid, every edge cell of the silhouette filled as a 0.5 × 0.5 pt square. On the case's top-right corner, a moat `(21.5, −1.5, 6, 6)` is cleared to transparent, then a red square `(22.5, −0.5, 4, 4)` in `#d6001c` is filled. |
| empty (no clock configured) | Case stroked, feet, nothing on the screen: no P, no badge. *Assumption, not approved in the browser;* it keeps the existing rule "the device is drawn, not its contents". |

Ink: white on a dark menu bar, black on a light one. The offline red cannot
come from a template image, so the glyph is drawn per appearance, which is
what the current `UserClock` palettes already do.

## Where it lands

- `Sources/PixbarTilesApp/MenuBarUserclock.swift`: the AppKit-free geometry of
  the glyph and the icon, replacing the user-clock map. It remains the single
  source for the generator and the bar.
- `Scripts/MakeIcon.swift`: rasterises the app icon (AppIcon set) and the
  glyph states from that geometry.
- Golden tests pin the device-pixel facts at @2x: knocked-out P cells and bezel
  ring are transparent online; the red square covers the expected device pixels
  and the moat is clear offline; the empty state has no P or red pixels.
