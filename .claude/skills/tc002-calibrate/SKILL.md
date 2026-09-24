---
name: tc002-calibrate
description: Settle a visual choice ON THE CLOCK — push candidate colours, glyph shapes, icons or spacings side by side in one labelled frame to the TC002 and let the user pick one by its letter. Use it yourself, without being asked, whenever a face detail is a judgement of the eye at LED scale: "цвет слишком оранжевый", "символ плохо читается", "покажи варианты", "какой оттенок", "сделай значок", a glyph that reads as another letter, a colour that may clash with an event's colour. NOT for whole-face layout or motion reviews — those go through `tc002-face-mockup`'s HTML and live demo.
---

# TC002 calibration

The panel is the only oracle for colour and small shapes: the LEDs' red channel
dominates (GitHub's gold `#E3B341` reads orange there), a 5 px glyph that looks
fine in a PNG reads as a letter on the clock, and there is no readback. So a
choice between candidates is made by showing them together on the panel — one
push, one question, one answer — never by describing them or by trying them one
push at a time.

You may do this on your own initiative. It touches only a `demo-*` page; the
app's `pbt-*` (and legacy `pct-*`) pages are never written.

## Procedure

1. **Build the candidates in the face's own terms** — the colours or glyph rows
   you would put in the generator. 2–4 candidates; more crowd 52×16.
2. **Self-check first**: `python3 calibrate.py … --dry-run`, then Read
   `calibrate.png`. Catch collisions and wrong shapes before the user sees them.
3. **Push**: the same command without `--dry-run`. It writes `demo-calibrate`
   and switches the clock to it.
4. **Ask ONE question**, naming the letters and what each is: "a — `#FFD84A`,
   b — …: which?" The clock's 200 proves nothing; the user's eye does.
5. **A refinement is a new push**, still side by side (a colour for the shape
   just picked, a variant of the winner). Keep the winner as candidate `a` so
   the comparison stays anchored.
6. **Record the choice where the design lives** — the face generator
   (`tc002-face-mockup/<face>/*.py`) — with a comment saying what was picked on
   the panel and when, and why the obvious alternative lost. Then re-render and
   re-open the face's HTML (its review gate).
7. **Clean up**: `python3 calibrate.py --remove` (and any other `demo-*` probe
   you left), then put the face's own demo back if the user was reviewing it.

## Commands

```bash
cd .claude/skills/tc002-calibrate
# colours: the same sample in each colour (small or big font)
python3 calibrate.py colours '#FFD84A' '#F2E04A' '#FFE680' --sample '★' --font big
# glyph shapes: comma-separated rows, '#' lit, before the same text
python3 calibrate.py glyphs '.###.,.###.,.....,#####,#####' '.#.,###,.#.,.#.,#.#' --text bob --colour '#909090'
# anything else: a JSON list of cells — label + parts (text, colour, font, optional glyph rows)
python3 calibrate.py spec cells.json
python3 calibrate.py --remove
```

`TC002_HOST` overrides the clock (default `192.168.1.72`). The glyph tables are
the faces' own (`github/ggen.py` over `weather/wgen.py`), so a winning glyph
draws the same once it moves into a face.

## What past calibrations settled

| Question | Candidates | Picked | Lesson |
|---|---|---|---|
| Star gold | `#FFD84A` / `#F2E04A` / `#FFE680` | `#FFD84A` | shift to gold by adding green, not by dropping red |
| Login prefix | `@` (two shapes), none, person glyph | grey person bust | `@` does not read at 5 px |
| Person colour | fork blue, grey `#909090`, lilac `#B48CFF` | grey | a mark in an event's colour reads as that event |
| Person shape | 4 busts / stick figure | wide 5 px bust | a gap between head and shoulders reads as a person |

## Related

- `tc002-face-mockup` — the face's HTML review and live demo; where the choice
  is recorded.
- `tc002-tile-screen` — colours in use and glyph rules the candidates must obey.
