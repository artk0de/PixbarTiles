# Night Light Tile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dinopowers:executing-plans (wraps superpowers:executing-plans) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Night light tile on the TC002: one of six warm scenes, dimmed to taste, that comes up by itself when its window opens and hands the panel back when it closes.

**Architecture:** The tile is the first kind built entirely on the plan-3 seams: `NightLightKind` + `NightLightTileConfig` in the kit, a connector whose reading IS the scene's `AnimatedPage.delivery`, and `NightLightWiring` in the app, which registers it, draws its settings block, and uses `arrived`/`left` for auto-show. None of the dispatch files change.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-09-29-night-light-tile-design.md` (behaviour, settings, policy) and `docs/superpowers/specs/2026-09-30-tile-kinds-and-animation-engine-design.md` §1–2 (kinds, engine).

## Global Constraints

- TC002 only. The catalogue offers the tile on no AWTRIX clock.
- The palette and scenes are the approved engine scenes (`NightLightScene.animatedScene`). No pixel is drawn outside the engine.
- Brightness: `(ch · level + 2) / 5`, levels 1…5, as `AnimatedPage` applies it. Levels 1–4 go through the panel gate (Task 6) before the setting ships.
- The default policy is Sleep only when Sleep can be named; otherwise 22:00–06:00.
- Auto-show acts on a change only: a launch never switches the clock.
- Business-logic tests are not rewritten. TDD. Check names with `get_naming_lexicon` before each commit, and reindex the clone after it. Never push.

---

### Task 1: `NightLightTileConfig`, `NightLightKind`, defaults (kit)

**Files:**
- Create: `Sources/PixbarKit/NightLight/NightLightTileConfig.swift`, `Sources/PixbarKit/Tiles/Kinds/NightLightKind.swift`, `Tests/PixbarKitTests/NightLightTileConfigTests.swift`
- Modify: `Sources/PixbarKit/Tiles/TileDefaults.swift` (`nightLightSleep`, `nightLightHours`), `Sources/PixbarKit/Tiles/TileKind.swift` (the list), `Sources/PixbarKit/Tiles/TileCatalogue.swift` (a kind narrows a live connector's models), `Tests/PixbarKitTests/TileKindsTests.swift` (table row)

**Produces:**
- `NightLightTileConfig { scene: NightLightScene, brightness: Int (1…5), speed: NightLightSpeed (.half/.normal/.double), stilled: Set<String>, autoShow: Bool, morningTileId: String? }`. Codable; the defaults (`.embers`, 5, `.normal`, `[]`, `true`, nil) write `{}`.
- `NightLightKind`:
  - id `"nightlight"`;
  - `.system`, `moon.stars`, "A warm scene for the night";
  - models `[.ulanziTC002]`, `.single`, silent.
- `TileCandidate(connector)` models = the connector's faces ∩ its kind's models, when a kind knows it.

Tests:
- config round-trip, and the defaults encode as `{}`;
- the `nightlight` key through `TileConfig`;
- the kinds table row;
- a candidate whose connector has both faces but whose kind is TC002-only lists only TC002.

Commit: `feat(kit): the night light's kind, config and default policies`.

### Task 2: `NightLightConnector` (kit)

**Files:**
- Create: `Sources/PixbarKit/NightLight/NightLightConnector.swift`, `Tests/PixbarKitTests/NightLightConnectorTests.swift`

**Produces:**
- `NightLightConnector(config: @Sendable () -> NightLightTileConfig, canNameSleep: @Sendable () -> Bool)`:
  - `Reading = UlanziDelivery`; `read()` = `AnimatedPage.delivery(scene.animatedScene, speed:, stilled:, brightness:)`; `ulanziFace` returns it.
  - `awtrixFace` is a blank text delivery, never offered (the kind is TC002-only).
  - Silent, ambient, `.single`, `defaultInterval` 3600.
  - `defaultPolicy` = `nightLightSleep` when `canNameSleep()` answers yes, else `nightLightHours`.

Tests: both policies; silent, ambient, single; `produceUlanzi()` equals `AnimatedPage.delivery` for the config; a stilled layer and a brightness reach the delivery.

Commit: `feat(kit): the night light connector reads its scene off the engine`.

### Task 3: `NightLightWiring` — registration and auto-show (app)

**Files:**
- Create: `Sources/PixbarTilesApp/Kinds/NightLightWiring.swift`, `Tests/PixbarTilesAppTests/NightLightWiringTests.swift`
- Modify: `Kinds/TileKindWiring.swift` (the list; `TileEnvironment.canNameSleep`), `ConnectorFactories.swift` / `AppComposition.swift` (hand in `canNameSleep`), `PanelGlyphs.swift` (`nightLightTile`)

**Behaviour:**
- `register` adds a factory reading the tile's own config.
- `namingInstance` gives the store its name.
- `arrived` with `autoShow` runs the tile, then shows its page.
- `left` with `autoShow` idles the page, then shows the morning tile: the configured `morningTileId` if that tile is on the clock, else `morningTile(clockId, excluding: key)`.
- With `autoShow` off, nothing happens.

Tests: those four cases through a recording `TileArrivalActions`, plus the wiring list staying exhaustive.

Commit: `feat(app): the night light comes up with its window and hands the panel back`.

### Task 4: `NightLightTileBlock` (app)

**Files:**
- Create: `Sources/PixbarTilesApp/NightLightTileBlock.swift`, `Tests/PixbarTilesAppTests/NightLightTileBlockTests.swift`
- Modify: `Kinds/NightLightWiring.swift` (`block`)

**Behaviour:**
- Scene picker (six names).
- Brightness, five steps.
- Speed ½× / 1× / 2×.
- One motion switch per layer key the chosen scene declares.
- "Turn on by itself".
- "In the morning show": First in order, or any other tile on this clock; disabled while auto-show is off.

Every change saves through `settings.setParameters(_:kind: NightLightKind.self)`.

Tests:
- the block's pure model: the motion keys per scene, the morning choices for a clock;
- a save through the context changes the stored config.

Commit: `feat(app): the night light's settings`.

### Task 5: Spec brought up to date (docs)

Update `2026-09-29-night-light-tile-design.md`:
- auto-show lives in the wiring's `arrived`/`left` (not a branch in `AppModel.reconcileTiles`);
- the config is a `TileParameters` under the kind;
- the TC002-only listing comes from kind narrowing;
- the approved descriptions of Horizon, Fireflies, Fireplace and Glow sit beside Embers and Red Moon.

Commit: `docs: the night light spec follows the kinds`.

### Task 6: Brightness gate on the panel (human)

Push one scene at levels 1–4 as `demo-*` pages, marked by letter, and ask the user whether the low steps are distinct. If they collapse, the brightness function is swapped in `nlengine.py` and `AnimatedPage` together and the oracle is re-recorded; otherwise the setting ships as is. Remove the demo pages afterwards.
