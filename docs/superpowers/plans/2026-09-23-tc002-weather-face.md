# TC002 Better Weather Face Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the TC002 weather page's still raster with the approved face: 47 animated 16×16 icons, a large temperature, a rotating detail line, and three layouts (Anchor / Pages / Hybrid).

**Architecture:** The skill's Python (`.claude/skills/tc002-face-mockup/weather/wgen.py`, `icons.py`) is the pixel source of truth. A recorder script turns it into JSON fixtures, and the Swift face is held to those fixtures pixel for pixel and delay for delay. Swift splits into:
- icon art (procedural frames);
- facts derived from a reading (which icon, moon, next sun event, rain window);
- the face (timelines per layout);
- the delivery (GIFs into an `UlanziScene`).

**Tech Stack:** Swift 6 package (PixelClockKit, PixelClockTilesApp), swift-testing, SwiftUI; Python 3 stdlib for the oracle.

**Spec:** `docs/superpowers/specs/2026-09-23-tc002-weather-face-design.md`

## Global Constraints

- Test command: `swift test --no-parallel` (two known timeout flakes in `UlanziClockSlotTests` under parallel runs).
- Every GIF carries full frames with one global palette (`FullFrameGif`); never sub-rectangle frames.
- Frame delays are whole centiseconds (multiples of 10 ms).
- Measured ceilings: an animated image may carry ≤ 480 frames, and a scene ≤ 136 000 bytes of base64.
- Default state change: 10 s. Default layout: Anchor. Default wind unit: m/s.
- Times are formatted in `TimeZone.current`, injected as a parameter for tests.
- Code, comments and commit messages are in English. Every commit ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Never hand-edit an oracle fixture. Change the Python and re-record.
- TDD: each task writes its failing test first and runs it red before implementing.

---

## File Structure

| File | Responsibility |
|---|---|
| `.claude/skills/tc002-face-mockup/weather/wgen.py` (modify) | Face pixels; gains `Reading`-shaped input, icon selection, derived facts |
| `Scripts/make_weather_face_oracle.py` (create) | Records `weather_icons_oracle.json`, `weather_face_oracle.json` |
| `Sources/PixelClockKit/Ulanzi/ProportionalGlyphs.swift` (modify) | Adds `h i k z x ° / ↑ ↓` and 8 wind arrows |
| `Sources/PixelClockKit/Ulanzi/BigDigitGlyphs.swift` (create) | `PixelFont.big`, the 5×9 temperature face |
| `Sources/PixelClockKit/Weather/WeatherIcon.swift` (create) | `enum WeatherIcon` (47 cases + `nodata`), `frames` |
| `Sources/PixelClockKit/Weather/WeatherIconArt.swift` (create) | Procedural primitives: disc, sun, moon, cloud, drops, flakes, bolt, streaks |
| `Sources/PixelClockKit/Weather/OpenMeteoSource.swift` (modify) | Wider request + optional fields on `WeatherReading` |
| `Sources/PixelClockKit/Weather/WeatherFacts.swift` (create) | Icon selection, moon phase, next sun event, rain chance, wind arrow/units |
| `Sources/PixelClockKit/Tiles/WeatherTileConfig.swift` (modify) | Layout, change interval, colour, wind, detail switches |
| `Sources/PixelClockKit/Weather/WeatherFace.swift` (create) | Temperature block, detail lines, pages, per-layout timelines, budget |
| `Sources/PixelClockKit/Ulanzi/UlanziScene.swift` (modify) | Ceilings 480 frames / 136 000 bytes |
| `Sources/PixelClockKit/Connectors/WeatherConnector.swift` (modify) | `ulanziOutput` → `WeatherFace.delivery`; TC001 colour setting |
| `Sources/PixelClockTilesApp/TileSettingsWindow.swift`, `TileSettingsModel.swift` (modify) | Controls, preview |
| `.claude/skills/tc002-face-mockup/SKILL.md`, `Sources/PixelClockKit/Ulanzi/CLAUDE.md`, `docs/HANDOFF.md` (modify) | Measured facts and the weather workflow |

---

### Task 1: Oracle — Python takes app readings, recorder writes fixtures

**Files:**
- Modify: `.claude/skills/tc002-face-mockup/weather/wgen.py`
- Create: `Scripts/make_weather_face_oracle.py`
- Create: `Tests/PixelClockKitTests/Fixtures/weather_icons_oracle.json`, `weather_face_oracle.json`
- Test: `Tests/PixelClockKitTests/WeatherOracleFixtureTests.swift`

**Interfaces:**
- Produces, in Python (`wgen.py`):
  - `Reading(code, is_day, t, fl, hum, wind_kmh, wdir, gust_kmh, uv, hi, lo, sunrise, sunset, hourly)`, where `sunrise` and `sunset` are lists of epochs for today and tomorrow, `hourly` is a list of `(epoch, temp_c, pop)`, and any field may be `None`.
  - `Config(layout, change_ms, units, wind_unit, feels_colour, items)`.
  - `select_icon(r, now_epoch)` returning a string.
  - `facts(r, cfg, now_epoch, tz)` returning a dict with `icon`, `moon`, `sun`, `rain`, `arrow`.
  - `timeline(r, cfg, now_epoch, tz)`. It returns `{"icon": [(grid16, ms)], "area": [(grid34x16, ms)]}` for Anchor and `{"full": [(grid52x16, ms)]}` for Pages and Hybrid.
- Produces, in fixtures:
  - `weather_icons_oracle.json`: `{"icons": {name: {"palette": ["rrggbb"], "frames": [{"ms": int, "rows": [16 strings of palette indices base36]}]}}}`.
  - `weather_face_oracle.json`: `{"timeZone": "UTC", "cases": [{"id", "now", "reading": {...}, "config": {...}, "facts": {...}, "frames": {...}}]}`, where frames are stored as rows of packed hex, as in `usage_face_oracle.json`.

- [ ] **Step 1: Write the failing fixture-shape test**

```swift
// Tests/PixelClockKitTests/WeatherOracleFixtureTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Suite struct WeatherOracleFixtureTests {
    @Test func bothFixturesAreRecordedAndCoverTheCatalogue() throws {
        let icons = try #require(Bundle.module.url(forResource: "weather_icons_oracle", withExtension: "json"))
        let face = try #require(Bundle.module.url(forResource: "weather_face_oracle", withExtension: "json"))
        let iconsJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: icons)) as? [String: Any]
        let names = (iconsJSON?["icons"] as? [String: Any])?.keys.sorted() ?? []
        #expect(names.count == 48)  // 47 approved icons + nodata
        let faceJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: face)) as? [String: Any]
        let cases = faceJSON?["cases"] as? [[String: Any]] ?? []
        #expect(cases.count >= 30)   // every icon rule × at least one layout, plus the corner cases
    }
}
```

- [ ] **Step 2: Run it — FAIL (fixture missing)**

Run: `swift test --no-parallel --filter WeatherOracleFixtureTests`

- [ ] **Step 3: Rework `wgen.py` input** so a case is a `Reading` as the app sees it:
  - temperatures arrive in °C and are converted to °F only for display (`round(c*9/5+32)`);
  - wind arrives in km/h and is converted to m/s (÷3.6), km/h, or mph (÷1.609344), rounded; wind colours are always computed from m/s;
  - times are epochs and are formatted in `tz`;
  - `hilo` uses today's daily bucket;
  - `rain` is the max `pop` over the hourly entries whose hour is ≥ the current hour and < current + 3 h;
  - `hourly` is the 11 entries from the current hour;
  - `sun` is the next event per spec §3.2;
  - the moon index follows spec §4.2.
  - Move icon choice into `select_icon` exactly per spec §4.1.
  - Move the demo's `hybrid_full` / `pages_full` / Anchor area+icon builders from `weather_demo.py` into `wgen.timeline`, together with the budget rule from spec §7. The rule: if a single GIF would exceed 480 frames or 136 000 base64 bytes, rebuild with `burst=2000`.
  - `weather_demo.py` then imports `wgen.timeline`. Keep `--scenario` working by converting `wgen.CASES` to `Reading`s.

- [ ] **Step 4: Write `Scripts/make_weather_face_oracle.py`** in the style of `make_usage_face_oracle.py`:
  - load the skill's `wgen` and `icons` by path;
  - write every icon in `icons.THEMES | DERIVED | MOON | PAGE_ICONS` plus `nodata`;
  - write the cases:
    - one per icon rule;
    - each layout on 3 readings;
    - °F + mph;
    - −35°;
    - 104 °F;
    - gusts;
    - each optional field missing;
    - no reading;
    - one case over budget (8 items, storm) that exercises the burst fallback.
  - Time zone UTC; `now` is a fixed epoch per case.

- [ ] **Step 5: Record and run the test — PASS**

Run: `python3 Scripts/make_weather_face_oracle.py && swift test --no-parallel --filter WeatherOracleFixtureTests`

- [ ] **Step 6: Live check that the Python still renders what was approved**

Run: `python3 .claude/skills/tc002-face-mockup/weather/wgen.py && python3 .claude/skills/tc002-face-mockup/weather/weather_demo.py --scenario 12 --layout hybrid`, then remove the page with `--remove`. (The parent session confirms with the user.)

- [ ] **Step 7: Commit** — `test: record the weather face oracle from the approved mockups`

---

### Task 2: Glyphs — the new 5 px marks and the 5×9 digits

**Files:**
- Modify: `Sources/PixelClockKit/Ulanzi/ProportionalGlyphs.swift`
- Create: `Sources/PixelClockKit/Ulanzi/BigDigitGlyphs.swift`
- Modify: `Sources/PixelClockKit/Ulanzi/PixelFont.swift` (add `public static let big`)
- Test: `Tests/PixelClockKitTests/WeatherGlyphTests.swift`

**Interfaces:**
- Produces: `PixelFont.proportional` covers `h i k z x ° / ↑ ↓ ⇑ ⇗ ⇒ ⇘ ⇓ ⇙ ⇐ ⇖`. `PixelFont.big` is a `PixelFontFace` with `height: 9`, `gap: 1`, and covers `0-9 - ° %`, with per-glyph widths as in `wgen.B`.
- Recorder addition: Task 1's recorder also writes `"glyphs": {"small": {ch: rows}, "big": {ch: rows}}` into `weather_face_oracle.json`. Do that in this task if Task 1 did not, and re-record.

- [ ] **Step 1: Failing test** — every glyph drawn with `PixelCanvas.drawText` equals the oracle rows:

```swift
@Suite struct WeatherGlyphTests {
    @Test func everyWeatherGlyphMatchesTheApprovedTable() throws {
        let oracle = try WeatherOracle.load()   // helper in Tests: decodes weather_face_oracle.json
        for (face, font) in [("small", PixelFont.proportional), ("big", PixelFont.big)] {
            for (character, rows) in try #require(oracle.glyphs[face]) {
                var canvas = PixelCanvas(width: 8, height: rows.count)
                canvas.drawText(String(character), at: .zero, ink: .white, font: font)
                let drawn = (0..<rows.count).map { y in
                    String((0..<rows[0].count).map { canvas[$0, y] == .white ? "#" : "." })
                }
                #expect(drawn == rows, "\(face) \(character)")
            }
        }
    }

    @Test func theUsageFaceGlyphsDidNotMove() throws {
        // UsageFaceOracleTests stays green: run it in the same step.
    }
}
```

- [ ] **Step 2: Run — FAIL.** Run: `swift test --no-parallel --filter WeatherGlyphTests`
- [ ] **Step 3: Add the glyphs.** Bit 0 is the leftmost column, as the file's header says. Transcribe each glyph from `wgen.G` / `wgen.B`, mirroring every row into binary.
- [ ] **Step 4: Run `--filter "WeatherGlyphTests|UsageFaceOracleTests"` — PASS**
- [ ] **Step 5: Commit** — `feat(font): the weather marks and the 5x9 temperature digits`

---

### Task 3: Icons — the 47 animations as Swift

**Files:**
- Create: `Sources/PixelClockKit/Weather/WeatherIconArt.swift` (primitives)
- Create: `Sources/PixelClockKit/Weather/WeatherIcon.swift`
- Test: `Tests/PixelClockKitTests/WeatherIconTests.swift`

**Interfaces:**
- Produces:

```swift
public enum WeatherIcon: String, CaseIterable, Sendable {
    case clearDay, clearNight, mainlyClearDay, mainlyClearNight
    case partlyCloudyDay, partlyCloudyNight, cloudDay, cloudNight
    case fog, rimeFog, drizzle, rain, heavyRain, sleet, freezingRain
    case showersDay, showersNight, snow, snowShowersDay, snowShowersNight
    case frost, thunder, storm, hail
    case windyDay, windyNight, cloudWindy, blizzard, hot, frostyClear
    case moon0, moon1, moon2, moon3, moon4, moon5, moon6, moon7
    case feelsWarm, feelsCold, humidity, wind, umbrella, uv, sunrise, sunset
    case nodata
    /// The animation: 16×16 canvases with their delays in milliseconds.
    public var frames: [(canvas: PixelCanvas, milliseconds: Int)] { get }
}
```

- [ ] **Step 1: Failing oracle test**

```swift
@Suite struct WeatherIconTests {
    @Test func everyIconReproducesTheApprovedAnimationExactly() throws {
        let oracle = try WeatherIconOracle.load()   // decodes weather_icons_oracle.json
        #expect(Set(oracle.icons.keys) == Set(WeatherIcon.allCases.map(\.rawValue)))
        for icon in WeatherIcon.allCases {
            let approved = try #require(oracle.icons[icon.rawValue])
            let drawn = icon.frames
            #expect(drawn.map(\.milliseconds) == approved.frames.map(\.ms), "\(icon) delays")
            for (index, (frame, want)) in zip(drawn, approved.frames).enumerated() {
                #expect(approved.rows(of: frame.canvas) == want.rows, "\(icon) frame \(index)")
            }
        }
    }
}
```

- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Port `icons.py`:**
  - Port function for function: `disc`, `cloud_mask`, `cloud`, `sun`, `moon`, `star`, `drops`, `flakes`, `bolt`, `streaks`, `slanted`, then each icon builder.
  - **Reproduce Python's arithmetic exactly.** `round()` is banker's rounding in Python 3: use `.toNearestOrEven`. Float comparisons use `Double`. `%` on negatives is floored in Python: write a `floorMod` helper. `//` is floor division: write `floorDiv`.
  - Colours come from `icons.C`; keep the names.
  - `nodata` is the grey `nt` cloud at (0,4), one frame of 1000 ms (`wgen.nodata_icon`).
- [ ] **Step 4: Run — PASS.** A pixel mismatch is a porting bug. Compare the named function with the Python line by line; never edit the fixture.
- [ ] **Step 5: Commit** — `feat(weather): the 47 approved 16x16 animations`

---

### Task 4: Data — the wider Open-Meteo request

**Files:**
- Modify: `Sources/PixelClockKit/Weather/OpenMeteoSource.swift`
- Test: `Tests/PixelClockKitTests/OpenMeteoSourceTests.swift` (extend the existing suite)

**Interfaces:**
- Produces: new optional properties on `WeatherReading`, all defaulting to `nil` in `init`:

```swift
public let windDirection: Double?     // degrees the wind comes FROM
public let windGusts: Double?         // km/h
public let uvIndex: Double?
public let todayHigh: Double?         // °C
public let todayLow: Double?          // °C
public let sunrises: [Date]           // today, tomorrow (empty when absent)
public let sunsets: [Date]
public let hourly: [HourlyPoint]      // empty when absent
public struct HourlyPoint: Sendable, Equatable { public let time: Date; public let temperature: Double; public let precipitationProbability: Int? }
```

- The request adds:
  - `current` += `wind_direction_10m,wind_gusts_10m,uv_index`;
  - `hourly=temperature_2m,precipitation_probability`;
  - `daily=temperature_2m_max,temperature_2m_min,sunrise,sunset`;
  - `timeformat=unixtime&timezone=auto&forecast_days=2`.

- [ ] **Step 1: Failing tests**
  - A live-shaped answer (below) decodes every field.
  - The request's query items include the new parameters.
  - An answer with `current` only still decodes: every new field is `nil` or empty.

```json
{"current":{"time":1790171100,"interval":900,"weather_code":3,"is_day":1,"temperature_2m":18.0,"apparent_temperature":18.2,"wind_speed_10m":7.3,"wind_direction_10m":101,"wind_gusts_10m":20.2,"relative_humidity_2m":77,"uv_index":0.55,"precipitation":0.0},
 "hourly":{"time":[1790110800,1790114400,1790118000],"temperature_2m":[15.6,15.4,15.0],"precipitation_probability":[60,35,15]},
 "daily":{"time":[1790110800,1790197200],"temperature_2m_max":[18.3,20.9],"temperature_2m_min":[12.8,11.6],"sunrise":[1790133381,1790219897],"sunset":[1790177183,1790263424]}}
```

- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Implement.**
  - Decode `hourly` and `daily` as optional containers of parallel arrays.
  - Zip hourly arrays to the shortest length.
  - Every new key uses `decodeIfPresent`.
- [ ] **Step 4: Run the suite — PASS**
- [ ] **Step 5: Commit** — `feat(weather): ask Open-Meteo for wind direction, gusts, UV, the day and the hours`

---

### Task 5: Facts — which icon, which moon, which sun event, which rain window

**Files:**
- Create: `Sources/PixelClockKit/Weather/WeatherFacts.swift`
- Test: `Tests/PixelClockKitTests/WeatherFactsTests.swift`

**Interfaces:**

```swift
public enum WindUnit: String, Codable, Sendable, CaseIterable { case metresPerSecond = "m/s", kilometresPerHour = "km/h", milesPerHour = "mph" }
public enum WeatherFacts {
    public static func icon(for reading: WeatherReading?, at now: Date) -> WeatherIcon
    public static func moonPhase(at date: Date) -> Int                 // 0...7
    public enum SunEvent: Equatable { case rise(Date), set(Date) }
    public static func nextSunEvent(after now: Date, in reading: WeatherReading) -> SunEvent?
    public static func rainChance(at now: Date, in reading: WeatherReading) -> Int?   // max pop, current hour + 2
    public static func nextHours(at now: Date, in reading: WeatherReading) -> [WeatherReading.HourlyPoint]  // ≤ 11
    public static func arrow(fromDegrees: Double) -> Character          // ⇑⇗⇒⇘⇓⇙⇐⇖, where the air goes
    public static func metresPerSecond(kilometresPerHour: Double) -> Double
    public static func speed(kilometresPerHour: Double, in unit: WindUnit) -> Int
}
```

- [ ] **Step 1: Failing tests.** One `@Test` per rule in spec §4.1, plus the oracle cross-check:

```swift
@Test func everyOracleCaseAgreesOnTheFacts() throws {
    for c in try WeatherOracle.load().cases {
        #expect(WeatherFacts.icon(for: c.reading, at: c.now).rawValue == c.facts.icon, "\(c.id)")
        if let r = c.reading {
            #expect(WeatherFacts.rainChance(at: c.now, in: r) == c.facts.rain, "\(c.id)")
        }
    }
}
@Test func theNewMoonOf2000IsPhaseZeroAndAFortnightLaterIsFull() {
    let newMoon = Date(timeIntervalSince1970: 947_182_440)          // 2000-01-06 18:14 UTC
    #expect(WeatherFacts.moonPhase(at: newMoon) == 0)
    #expect(WeatherFacts.moonPhase(at: newMoon.addingTimeInterval(14.765 * 86_400)) == 4)
}
@Test func afterSunsetTheNextEventIsTomorrowsSunrise() { /* reading with sunrises/sunsets, now = today's sunset + 1 s → .rise(tomorrow) */ }
@Test func beforeSunriseTheNextEventIsTodaysSunrise() { /* now = today's sunrise − 1 s → .rise(today) */ }
@Test func theArrowPointsWhereTheAirGoes() { #expect(WeatherFacts.arrow(fromDegrees: 225) == "⇗"); #expect(WeatherFacts.arrow(fromDegrees: 0) == "⇓") }
@Test func stormNeedsFourteenMetresPerSecond() { /* code 95, wind 50.4 km/h (14 m/s) → .storm; 49 km/h → .thunder */ }
```

  Write each commented body as real assertions with the concrete numbers given.
- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Implement.** Follow spec §4.1–§4.2 and the Python `select_icon` / `facts` from Task 1. Their outputs must agree on every oracle case.
- [ ] **Step 4: Run — PASS**
- [ ] **Step 5: Commit** — `feat(weather): read the icon, the moon, the sun and the rain off a reading`

---

### Task 6: Tile settings — the new switches, and old records still decode

**Files:**
- Modify: `Sources/PixelClockKit/Tiles/WeatherTileConfig.swift`
- Modify: `Sources/PixelClockKit/Connectors/WeatherConnector.swift` (TC001 colour only)
- Test: `Tests/PixelClockKitTests/WeatherTileConfigTests.swift` (extend or create)

**Interfaces:**

```swift
public enum Layout: String, Codable, Sendable, CaseIterable { case anchor, pages, hybrid }
public enum Detail: String, Codable, Sendable, CaseIterable { case feels, humidity, wind, hilo, rain, uv, sun, hourly }
public static let changeEverySteps: [TimeInterval] = [3, 5, 8, 10, 15]
public var layout: Layout                  // .anchor
public var changeEvery: TimeInterval       // 10
public var feelsLikeColour: Bool           // true
public var showsWind: Bool                 // true
public var windUnit: WindUnit              // .metresPerSecond
public var showsHiLo: Bool                 // true
public var showsRainChance: Bool           // true
public var showsUV: Bool                   // false
public var showsSunEvents: Bool            // false
public var showsHourly: Bool               // true
public var details: [Detail] { get }       // Detail.allCases filtered by the switches (feels ← showsFeelsLike, humidity ← showsHumidity)
```

- [ ] **Step 1: Failing tests:**
  - `{"latitude":55.7,"longitude":37.6}` decodes to every default above.
  - A full config round-trips.
  - `details` follows the switches in the spec's order.
  - The TC001 `output(for:config:)` colours from the felt temperature exactly when `feelsLikeColour` is on, regardless of `showsFeelsLike`.
- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Implement.**
  - New `CodingKeys`, `decodeIfPresent` with defaults, encode everything.
  - In `WeatherConnector.output(for:config:)` and `canvas(for:config:)`, compute `felt` from `config.feelsLikeColour`.
- [ ] **Step 4: Run — PASS** (the existing weather tests too: `--filter Weather`)
- [ ] **Step 5: Commit** — `feat(weather): the face's settings, defaulted so every stored tile still reads`

---

### Task 7: The face — timelines for Anchor, Pages and Hybrid

**Files:**
- Create: `Sources/PixelClockKit/Weather/WeatherFace.swift`
- Test: `Tests/PixelClockKitTests/WeatherFaceTests.swift`

**Interfaces:**

```swift
public enum WeatherFace {
    public struct Frame: Sendable, Equatable { public let canvas: PixelCanvas; public let milliseconds: Int }
    /// Anchor: the icon and the right area loop independently.
    public struct Layered: Sendable, Equatable { public let icon: [Frame]; public let area: [Frame] }  // 16×16, 34×16
    public enum Timeline: Sendable, Equatable { case layered(Layered), single([Frame]) }  // single: 52×16
    public static func timeline(reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone) -> Timeline
    /// The whole panel as one sequence, for the preview (Anchor merges both clocks).
    public static func preview(reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone) -> [Frame]
    static let maxFrames = 480, maxBase64Bytes = 136_000, burstMilliseconds = 2_000
}
```

- [ ] **Step 1: Failing oracle test**
  - For every case in `weather_face_oracle.json`, build the `WeatherReading` and the `WeatherTileConfig` from the case.
  - Call `timeline(…, now: c.now, timeZone: UTC)`.
  - Compare delays and every frame's hex rows to `c.frames`. Report the first differing row, as `UsageFaceOracleTests` does.
  - Add explicit tests:
    - `aLayoutWithOneDetailIsAStill`;
    - `theOverBudgetCaseFallsBackToBursts` (the recorded 8-item storm case: frames ≤ 480);
    - `noReadingDrawsDashesAndTheGreyCloud`.
- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Port `wgen.timeline`:**
  - the temperature block, detail lines with `gap_after`, `hilo_parts`, the hourly chart, the Pages pages, the transitions (spec §2.2), `play(tl, total, burst)`, the Hybrid icon slide and the budget rule;
  - reuse `PixelCanvas.drawText(font:)` with `PixelFont.proportional` / `.big`, and `PixelCanvas.draw(_:at:)` for blits;
  - build the colour helpers (`TemperatureColour`, wind, UV) from spec §3.4. `TemperatureColour` already exists. Check that its interpolation rounds the way `wgen.temp_colour` does. If they disagree, fix the Swift, unless the Python is the one that is wrong; then fix the Python and re-record.
- [ ] **Step 4: Run — PASS**
- [ ] **Step 5: Commit** — `feat(weather): the TC002 face — Anchor, Pages and Hybrid timelines`

---

### Task 8: Delivery — GIFs, measured ceilings, the connector

**Files:**
- Modify: `Sources/PixelClockKit/Ulanzi/UlanziScene.swift` (`maxAnimatedFrames = 480`, `maxBase64Bytes = 136_000`, doc comments citing the 2026-09-23 measurement)
- Modify: `Sources/PixelClockKit/Weather/WeatherFace.swift` (add `delivery`)
- Modify: `Sources/PixelClockKit/Connectors/WeatherConnector.swift` (`ulanziOutput` → `WeatherFace.delivery`, `now: Date()`, `timeZone: .current`)
- Test: `Tests/PixelClockKitTests/UlanziSceneTests.swift` (boundary tests), `WeatherFaceTests.swift`, `WeatherConnectorTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public static func delivery(reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone) -> UlanziDelivery
  ```

  - `.layered` becomes one `UlanziFrame(duration: 5, image: [icon at (0,0) 16×16, area at (18,0) 34×16])`.
  - `.single` becomes one 52×16 image at (0,0).
  - When encoding fails, the delivery falls back to the first frame's `drawCommands()`, as `UsageFace.delivery` does.

- [ ] **Step 1: Failing tests:**
  - 480 frames pass and 481 throw; 136 000 bytes pass and 136 001 throw. Update the existing boundary tests that pinned 50 and 60 000. Their names say "documented" — rename them to say "measured".
  - The Anchor delivery has two images at (0,0) and (18,0).
  - Each image's GIF bytes equal `FullFrameGif.encode` of the timeline.
  - The worst oracle case's delivery passes `scene.jsonObject()`.
- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Full suite — `swift test --no-parallel` — PASS**
- [ ] **Step 5: Commit** — `feat(weather): ship the face; the scene ceilings are the measured ones`

---

### Task 9: Settings window and preview

**Files:**
- Modify: `Sources/PixelClockTilesApp/TileSettingsWindow.swift` (`WeatherTileControls`)
- Modify: `Sources/PixelClockTilesApp/TileSettingsModel.swift` (setters through `edit`)
- Modify: the preview path the usage face uses to play its GIF (`PixelPreview.swift`), fed from `WeatherFace.preview`
- Test: `Tests/PixelClockTilesAppTests/TileSettingsModelTests.swift` (extend)

**Interfaces:**
- Produces: `TileSettingsModel.setLayout(_:)`, `setChangeEvery(_:)`, `setFeelsLikeColour(_:)`, `setShowsWind(_:)`, `setWindUnit(_:)`, `setShowsHiLo(_:)`, `setShowsRainChance(_:)`, `setShowsUV(_:)`, `setShowsSunEvents(_:)`, `setShowsHourly(_:)`. Each edits the draft and saves, as `setUnits` does.

- [ ] **Step 1: Failing model tests** — one per setter: the draft changes, the store receives it.
- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Implement** the setters and the controls, in this order:
  1. Layout (segmented: Anchor / Pages / Hybrid);
  2. Change every (picker: 3/5/8/10/15 s);
  3. Units;
  4. Wind unit;
  5. Feels-like colour;
  6. Show feels-like;
  7. Show humidity;
  8. Wind;
  9. Hi/Lo;
  10. Rain chance;
  11. UV;
  12. Sunrise/sunset;
  13. Hourly chart;
  14. Reset to defaults.

  The TC002 preview plays the `WeatherFace.preview` frames at their own delays.
- [ ] **Step 4: Full suite — PASS**; `./Scripts/bundle.sh` builds and signs.
- [ ] **Step 5: Commit** — `feat(app): the weather face's settings and a preview that plays it`

---

### Task 10: Knowledge — skill, navigator, handoff

**Files:**
- Modify: `.claude/skills/tc002-face-mockup/SKILL.md`. Add a weather section: files, `weather_demo.py` flags (`--layout`, `--mode`, `--items`, `--interval`, `--burst`, `--remove`), and re-recording with `Scripts/make_weather_face_oracle.py`. Replace the "≤ 50 frames / 60 KB" line with the measured ceilings.
- Modify: `Sources/PixelClockKit/Ulanzi/CLAUDE.md`. Add the measured facts, stated once:
  - two GIFs drift;
  - Mac re-push is not frame-accurate;
  - one GIF at 478 frames / 135 KB plays on time;
  - what must change with a page must slide with it.
- Modify: `docs/HANDOFF.md`. Add a section for the weather face, pointing at the spec and plan.

- [ ] **Step 1: Write the three edits**
- [ ] **Step 2: `swift test --no-parallel` — still PASS** (`Package.swift` already excludes `Ulanzi/CLAUDE.md`)
- [ ] **Step 3: Commit** — `docs: what the clock taught us about GIFs, and the weather workflow`

---

## Finish

1. Rebuild with `./Scripts/bundle.sh` and relaunch the app from this worktree's `build/`.
2. Live validation on the TC002, user-confirmed: Anchor, Pages and Hybrid on the live reading, °F, and no data (the place field emptied or the network off).
3. Merge `feat/tc002-weather-face` into `master` with `--no-ff`, through an integration worktree. Never touch the main checkout.
