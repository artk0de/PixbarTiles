# Weather — navigator

Local knowledge for editing the weather tile's kit code: the TC002 face, its
facts and its data. Cite code by symbol, never by line. The design is the spec
`docs/superpowers/specs/2026-09-23-tc002-weather-face-design.md`; screen and
motion rules are owned by the `tc002-tile-screen` / `tc002-ticker-motion`
skills; wire facts by `../Ulanzi/CLAUDE.md`.

## The Python is the pixel oracle

`WeatherFace`, `WeatherFaceLines`, `WeatherFaceTimelines`, `WeatherFacts`,
`WeatherIconArt` and the `big`/`proportional` glyph tables are ports of
`.claude/skills/tc002-face-mockup/weather/{wgen.py,icons.py}`. Tests hold them
to fixtures recorded from that Python, pixel for pixel and delay for delay.

- Change order: Python → `python3 Scripts/make_weather_face_oracle.py` (from
  the repo root) → Swift. Never edit `weather_face_oracle.json` /
  `weather_icons_oracle.json` by hand; re-recording is deterministic, so an
  unexpected diff in an unrelated case is a bug in your Python change.
- A new tile switch goes into the recorder's `SWITCHES`, but NOT into `ALL`
  unless every existing case should change — otherwise unrelated cases stop
  being byte-identical.
- Arithmetic must be Python's, not Swift's defaults: round half to EVEN
  (`.toNearestOrEven`), floored `%` and `//` for negatives. The Swift default
  rounding moved a wind arrow and a moon phase on their boundaries.
  `TemperatureColour` rounds half-even too — it is shared with the TC001 face,
  so a change there moves TC001 digit colours as well.

## Facts, not guesses

- Icon choice lives in `WeatherFacts.icon(for:at:showsMoon:)` — spec §4.1 owns
  the thresholds (storm/blizzard wind, sleet band, hot/frosty clear by day). A
  clear night (WMO 0) is the moon in its phase ONLY when the tile shows the
  moon; otherwise `clearNight`.
- `moonPhase(at:)` is the synodic month off one new moon (epoch 947 182 440),
  eight phases — about a day off the true phase, accepted.
- Rain chance and the hourly chart read hours in the Mac's `TimeZone.current`
  against Open-Meteo's unixtime series; the chart window is [current hour,
  +11 h) and may hold fewer bars.
- A missing field drops its line/page (see the spec's missing-data list); a
  missing reading is the single `no data` state. Never draw a placeholder.

## Data

`OpenMeteoSource` asks for `timeformat=unixtime&timezone=auto&forecast_days=2`
and keeps wind in km/h; unit conversion happens at draw time from
`WeatherTileConfig.windUnit`. Every added field is optional — an old or partial
response must still decode.

## Delivery

`WeatherFace.delivery` picks the shape per layout: Anchor = two independent
GIFs (icon at (0,0), area at (18,0)); Pages/Hybrid = one 52×16 GIF, falling
back to burst when it would pass `UlanziScene`'s ceiling. The settings
preview plays `WeatherFace.preview` at its own delays; `WeatherConnector
.canvas(for:config:)` survives for tests only.
