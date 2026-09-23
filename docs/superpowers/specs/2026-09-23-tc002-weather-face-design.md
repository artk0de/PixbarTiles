# TC002 Better Weather face — design

Date: 2026-09-23. Status: approved in the browser mockups and live on the
TC002 (192.168.1.72). Pixel source of truth: the `tc002-face-mockup` skill's
`weather/` directory (`wgen.py`, `icons.py`); `weather_demo.py` is the live
demo that validated every layout on the clock.

## 1. Goal

The TC002 weather page is currently one still raster: the temperature in the
3×5 font at scale 2 and a band with `H78%` and `~18°`, no icon, no motion. The
TC001 has animated weather icons. The redesign gives the 52×16 panel:

- a 16×16 animated icon for every weather state Open-Meteo can report, plus
  states derived from wind, temperature and the moon;
- a large temperature;
- rotating details (feels-like, humidity, wind, hi/lo, rain chance, UV,
  sunrise/sunset, an hourly chart), each switchable per tile;
- three layouts the tile chooses between: **Anchor**, **Pages**, **Hybrid**.

## 2. Layouts

The panel is split into the icon (x 0–15), a 2 px gutter, and the right area
(x 18–51, 34 px wide). A *state* is one detail on screen; the state changes
every `changeEvery` seconds (tile setting, default **10 s**).

| Layout | What moves | Delivery |
|---|---|---|
| **Anchor** | The temperature (rows 0–8) never moves. The detail line (rows 11–15) slides up and the next one slides in. The weather icon loops on its own. | Two GIFs in one frame's `image[]`: the icon (16×16 at 0,0) and the right area (34×16 at 18,0). |
| **Pages** | Each state is a whole page — its own icon, one big figure, a label. On a change the WHOLE page, icon and text together, slides up. | One 52×16 GIF. |
| **Hybrid** | Anchor's fixed temperature and sliding detail line, but each line brings its own icon; the icon slides up together with the line. | One 52×16 GIF. |

### 2.1 Why the deliveries differ (measured on the clock, 2026-09-23)

- Two GIFs on one page each play their own delays, but they **drift**: the
  panel pays a per-frame cost, so a 321-frame icon GIF falls behind a 36-frame
  area GIF. Two GIFs are therefore only used where nothing has to line up —
  Anchor, whose icon is independent of the text.
- Re-pushing the page from the Mac once per state is not frame-accurate
  either: pushes left on time (±80 ms) and the icon still missed the text.
- Inside ONE GIF everything is in step by construction. One 52×16 GIF of
  **478 frames / 135 240 bytes of base64** played smoothly and on time. The
  documented ceilings (50 frames, 60 KB) are wrong for this panel.
- A change that the icon has to follow must MOVE with it. Swapping the icon
  halfway through the slide read as "icon early"; swapping it when the line
  landed read as "icon late". Only the shared slide read as right.

### 2.2 Transitions (exact timing is the oracle's)

- Anchor and Hybrid detail line: slides up 1 row per step, 6 steps of 60 ms,
  with one blank row between the outgoing and incoming line.
- Hybrid icon: slides up 3 rows per step over the same 6 steps, 2 blank rows
  between the outgoing icon (frozen on its current frame) and the incoming one
  (its first frame).
- Pages: the whole 52×16 page slides up 2 rows per step, 8 steps of 40 ms,
  2 blank rows between pages.
- Every delay is a whole number of centiseconds, so the GIF says exactly what
  the timeline says.
- A layout with a single state has no transition and is a still dwell.

## 3. Content

### 3.1 Temperature block (Anchor, Hybrid; the first page of Pages)

- Large 5×9 digits (`wgen.B`), whole degrees, rounded, in the tile's scale.
- A small grey `c` or `f` after the degree sign names the scale. A
  temperature always names its scale, the feels-like page included.
- Colour: `TemperatureColour` of the felt temperature when **Feels-like
  colour** is on (falling back to the air when the reading has no felt
  value), of the air temperature when it is off.
- No reading: `--°` in dim grey, the detail line `no data`, a grey cloud icon.

### 3.2 Detail lines (Anchor and Hybrid ticker)

Labels are grey (`#606060`); values carry the colour. A grey word label is
followed by 3 blank px, a value by 2, an arrow by 1 — the usage face's
label/value rule. All glyphs are 5 px tall.

| Key | Line | Value colour | Hybrid icon |
|---|---|---|---|
| `feels` | `fl -19°` | TemperatureColour(felt) | thermometer, warm at felt ≥ 10 °C, else cold |
| `humidity` | `h 85%` | `#4DA6FF` | filling drop |
| `wind` | `⇗ 5 m/s`; with gusts ≥ 5 m/s above the mean: `⇗ 17 g 25` | by speed, §3.4 | wind |
| `hilo` | `↑-9° ↓-15°`; the degree signs drop when the line would pass 34 px | TemperatureColour of each | weather |
| `rain` | `rain 90%` | `#4DA6FF` from 30 %, grey below | umbrella |
| `uv` | `uv 7` | WHO scale, §3.4 | sun with violet rays |
| `sun` | `set 19:42` or `rise 6:48` | `#FFB52E` | sunset or sunrise |
| `hourly` | 11 bars, §3.3 | TemperatureColour per bar | weather |

Order on screen is the table's order, filtered by the tile's switches.

- Wind arrow points where the air GOES: Open-Meteo reports where it comes
  from, the arrow is that bearing + 180°, rounded to 8 directions.
- `rain` is the highest precipitation probability over the current hour and
  the next two.
- `sun` is the next event after now: today's sunrise if it has not happened,
  else today's sunset if it has not happened, else tomorrow's sunrise. The
  hour has no leading zero; the time is in `TimeZone.current`.
- `hilo` is today's daily max/min, today as the service's local day.

### 3.3 Hourly chart

Eleven bars for the current hour and the next ten, each 2 px wide with 1 px
between (33 px). Bar height is 1–4 px, scaled between the lowest and highest
of those eleven temperatures (all equal: 2 px). The bar is coloured by its
temperature; an hour with precipitation probability ≥ 50 % gets a `#D8F0FF`
cap pixel row above its bar.

### 3.4 Colour scales

- Wind (m/s, whatever the display unit): < 3 `#CFE8F0` calm, < 8 `#7CFC9A`,
  < 14 `#FFD24A`, < 20 `#FF8C1A`, else `#FF3B30`.
- UV: < 3 `#3EC43E`, < 6 `#FFD24A`, < 8 `#FF8C1A`, < 11 `#FF3B30`, else
  `#B45AFF`.

### 3.5 Pages (layout B)

| Page | Icon | Big figure | Bottom line |
|---|---|---|---|
| temperature (always) | weather | temperature + scale | hi/lo |
| `feels` | thermometer | felt temperature + scale | `feels` |
| `humidity` | drop | `85%` | `humidity` |
| `wind` | wind | speed, unit in grey beside it | arrow, and `g 25` with gusts |

The other detail keys have no page in this layout.

### 3.6 Units

Temperature: °C or °F (existing setting). Wind: new setting **m/s**
(default), **km/h**, **mph**. The service keeps answering km/h; the face
converts.

## 4. Icons

47 procedural 16×16 animations (`icons.py`): shared primitives (sun disc with
breathing rays, crescent/phase moon, a lit cloud union, drops, flakes, bolt,
wind streaks) and per-icon motion. Frame delays are multiples of 10 ms.

### 4.1 Selection (first match wins)

Wind thresholds are in m/s. `hot` = air ≥ 30 °C, `frosty` = air ≤ −10 °C,
`windy` = wind ≥ 10 m/s or gusts ≥ 15 m/s.

1. No reading → `nodata`.
2. 96, 99 → `hail`. 95 → `storm` when wind ≥ 14 m/s or gusts ≥ 20 m/s, else
   `thunder`.
3. 71, 73, 75, 77, 85, 86 → `blizzard` when windy; else 85, 86 →
   `snowShowersDay` / `snowShowersNight`; else `snow`.
4. 56, 57, 66, 67 → `freezingRain`.
5. 51, 53, 55, 61, 63, 65, 80, 81, 82 → `sleet` when the air is 0…+2 °C;
   else 51–55 `drizzle`; 61, 63 `rain`; 65, 82 `heavyRain`; 80, 81
   `showersDay` / `showersNight`.
6. 45 → `fog`; 48 → `rimeFog`.
7. 0–3 and every other code (the existing clear fallback):
   - windy → `windyDay` / `windyNight` for 0–2, `cloudWindy` for 3;
   - 0, 1 by day → `hot` or `frostyClear` when those hold;
   - 0 → `clearDay`, at night `moon0…moon7` (§4.2);
   - 1 → `mainlyClearDay` / `mainlyClearNight`;
   - 2 → `partlyCloudyDay` / `partlyCloudyNight`;
   - 3 → `cloudDay` / `cloudNight`.

`clearNight` and `frost` stay in the catalogue without a rule of their own:
`clearNight` is the art a moon phase falls back to, `frost` is approved art
kept for a frost warning. The catalogue is the approved art; the rules decide
what shows.

### 4.2 Moon

Age = days since the new moon of 2000-01-06 18:14 UTC, modulo the synodic
month 29.530588853 days, as a fraction of it; phase index =
`round(age × 8) mod 8`. 0 new, 2 first quarter (right lit), 4 full,
6 last quarter.

### 4.3 Page and detail icons

`feelsWarm`, `feelsCold`, `humidity`, `wind`, `umbrella`, `uv`, `sunrise`,
`sunset`.

## 5. Data

One Open-Meteo request, as now, with more fields:

- `current`: the existing seven plus `wind_direction_10m`,
  `wind_gusts_10m`, `uv_index`.
- `hourly`: `temperature_2m`, `precipitation_probability`.
- `daily`: `temperature_2m_max`, `temperature_2m_min`, `sunrise`, `sunset`.
- `timeformat=unixtime`, `timezone=auto`, `forecast_days=2`.

Verified live on 2026-09-23: every field is present, times are epoch seconds,
the daily buckets are the place's local days.

`WeatherReading` grows optional fields — wind direction, gusts, UV, today's
high and low, sunrise and sunset for today and tomorrow, and the hourly
series (time, temperature, precipitation probability). Each is optional and
decoded with `decodeIfPresent`: a response missing one drops that detail, not
the poll. A detail whose data is missing is left out of the rotation.

## 6. Tile settings

`WeatherTileConfig` gains, each defaulted when absent so every stored record
decodes:

| Setting | Values | Default |
|---|---|---|
| Layout | Anchor / Pages / Hybrid | Anchor |
| Change every | 3, 5, 8, 10, 15 s | 10 s |
| Feels-like colour | on / off | on |
| Wind | on / off | on |
| Wind unit | m/s / km/h / mph | m/s |
| Hi/Lo | on / off | on |
| Rain chance | on / off | on |
| UV | on / off | off |
| Sunrise/sunset | on / off | off |
| Hourly chart | on / off | on |

The existing Units, Show humidity and Show feels-like stay; Show feels-like
now means the `feels` line and page only. The colour is its own setting. The
TC001 face reads **Feels-like colour** for its digit colour, so one switch
means one thing on both clocks.

The settings window's weather block gets the pickers and switches in that
order. The TC002 preview plays the face's GIF(s) as the usage face's preview
does.

## 7. Delivery and ceilings

- Every GIF carries full frames with one global palette. Sub-rectangle frames
  smear on this decoder (HANDOFF 6f).
- `UlanziScene` ceilings move from the documented values to the measured
  ones: an animated image may carry up to **480 frames** and a scene up to
  **136 000 bytes** of base64. Each is pinned by a boundary test.
- The face guarantees it fits. When a composed single GIF would pass a
  ceiling, every state's icon plays whole loops for at least 2 s after its
  change and then rests on its first frame (68–156 frames for the approved
  scenarios). Measured: the worst live case, storm with all six default lines,
  is 478 frames and fits without it; more lines can need it.
- The poll cadence is unchanged (600 s); each push restarts the cycle.

## 8. Testing

- A pixel oracle, `Scripts/make_weather_face_oracle.py`, imports the skill's
  `wgen.py` / `icons.py` and records:
  - every icon's frames and delays;
  - Anchor's area and icon timelines;
  - Pages' and Hybrid's single timelines;
  for a set of readings covering the design's corner cases: every icon rule,
  °F and mph, −35°, a three-digit temperature, gusts, missing fields, no
  reading. The Swift face is held to them pixel for pixel and delay for
  delay. Change the design in the skill and re-record, never the fixture by
  hand.
- The mockup scripts take readings as the app sees them (°C, km/h, epochs),
  so the oracle and the Swift face start from the same input.
- Unit tests:
  - icon selection per rule;
  - moon phase against known dates;
  - the next sun event around midnight and after sunset;
  - the rain window;
  - wind conversion and arrow bearing;
  - config decoding of old records;
  - the budget fallback;
  - the new ceilings at their boundaries;
  - the decoder with and without each new field.
- Live validation on the TC002 before merge: each layout, °F, no data.

## 9. Out of scope

Air quality (a second API), minutely "rain in N minutes", a tomorrow icon,
pressure trend.
