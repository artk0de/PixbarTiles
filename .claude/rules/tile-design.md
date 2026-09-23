# Designing a tile's screen

Designing a new tile, or a new page, state or animation of an existing one, on
either clock model (TC002 or AWTRIX) ALWAYS goes through the
`tc002-face-mockup` skill: invoke it before proposing any layout, and render
every candidate as LED dots in its self-contained `index.html`.

- The design is approved in the browser, then on the real clock, and only then
  written in Swift. No Swift face, no fixture, no glyph table before the user
  has signed off on the rendered frames.
- An ASCII sketch in chat is a way to ask a question, never a design the user
  approved. Once the question is answered, the HTML is where the design lives.
- The mockup skill owns the tooling; `tc002-tile-screen` owns what a screen
  must obey (zones, fonts, 34 px fitting, icons); `tc002-ticker-motion` owns
  how it moves. Load both alongside it.
- A colour, glyph shape or icon variant the eye must judge is settled on the
  clock with `tc002-calibrate` — candidates side by side, picked by letter —
  and you may run it without being asked.

Why: a clock screen is judged by eye at LED scale. Clipping, glyph collisions,
worst-case widths and GIF timing are invisible in prose and in a green suite,
and the generator's frames are the pixel oracle the Swift face is tested
against — a design that skipped them has no oracle.
