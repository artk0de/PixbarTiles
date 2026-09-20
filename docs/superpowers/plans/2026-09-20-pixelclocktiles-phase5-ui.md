# PixelClockTiles Phase 5 — the UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. When executing, follow every RED-first
> step: write the test, run it, watch it fail, then implement. Read `docs/HANDOFF.md`
> § 'How this branch finds defects' before the first task.

## Goal

The panel learns about clocks. One segment per clock, one row per tile on the
selected clock, tile detail with the shared policy editor, a Clocks section in
the general settings, and `MenuPanel.swift` split into the parts the spec
names, so the next change to a row is a change to one small file.

Phase 5 also retires the launch fallbacks phase 1 left behind: a launch
without clocks is a state the user can reach and answers, not a clock created
in the dark.

The work splits in two parts:

- **Part 5a** — views and plain types only. No task touches `AppModel.swift`,
  and no task rewires `MenuPanel.swift`. Every task runs on the integrated
  tree as it stands and can land in any order, in parallel with part 5b.
- **Part 5b** — the `AppModel` work and the switch-over that puts the parts on
  the panel. Sequential, and every task opens by merging the integration
  branch.

## Architecture

```text
AppModel (5b) ── published per-clock projection ──┐
  selectedClockId                                 │
  rows · status · availability · surfaces         ▼
┌─────────────────────────── MenuPanel body ────────────────────────────┐
│ ClockSwitcher   ClockStatusBlock   TileRow × n   AddTileMenu   lastRow│
└───────────────────────────────────────────────────────────────────────┘
        │ surface switch, like settings and the History today
        ▼
   TileDetail ── TilePolicyEditor ── connector block (location · history · vpn)
   ClocksSettings (inside SettingsSheet, where deviceHostSection was)

Part 5a builds the right side against values and closures it defines itself.
Part 5b makes `AppModel` produce those values. Nothing reaches `master` before
Task 12 connects them.
```

## Tech stack

- Swift 6.3.3, SwiftPM, macOS 14 floor, `swift-testing` (`#expect` / `#require`).
- Swift 6 strict concurrency; `@MainActor` views and `AppModel`, as today.
- SwiftUI `MenuBarExtra` in `.window` style. No third-party dependencies, ever.
- View proofs draw into a bitmap at the shipped width — the technique of
  `PanelRenderingTests`, which exists because deleting a whole section from
  `body` left every other kind of test green.

## Spec

- `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md`
  — § Menu bar UI (the panel, tile detail, general settings, behaviour) is
  this phase's contract, and § Persistence and migration fixes
  `selectedClockId`.
- `docs/HANDOFF.md` — § 'What later tasks owe' (phase 1's owed items),
  lane C's C1–C6, § 'PixelClockTiles Phase 3b' (the two phase-4 stopgaps:
  `NoClockHost` and the `start()` guard).

## Global constraints

- RED-first everywhere: each task writes failing tests first and shows the
  failure before implementing.
- `swift test -j 2 --no-parallel` is the verification command. Full-suite runs
  pass `--skip nothingButTheAnecdotesEverPutsSoundInTheRoom`; that one test
  runs alone at the end of the session, never inside a parallel run.
- **Part 5a never touches `AppModel.swift` and never edits
  `MenuPanel.swift` or `SettingsSheet.swift`.** New files only. The
  switch-over is Task 12, alone. This constraint is what lets the two parts
  run in parallel without colliding.
- No test ever touches the network (phase-3 D13, still in force). The TC002 at
  192.168.1.72 is READ-ONLY for development.
- English comments, identifiers, commit messages.
- Stages name explicit paths (`git add <paths>`), never `git add -A`.

## Decisions

| #    | Decision                                                                                                                                                                                                                                                                                        |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1   | **5a is `AppModel`-free.** Each view takes the values it needs as parameters — a `TileRowValue`, an `[AddTileMenuItem]`, closures for actions — defined in the view's own file. `AppModel` starts producing them in 5b. The parts are strangers until Task 12 joins them, and either part can land first. |
| D2   | **The moving part is named, not pinned.** Lane 4b is rewiring `AppModel` as this plan is written — battery healths, init parameters, the poll rewrite, `scheduleHold`. Every 5b task opens with: merge `feat/pixelclocktiles-int` first, weave with 4b's wiring, keep both intents. The steps say what becomes true; no step quotes today's field shapes. |
| D3   | **The selection persists.** `selectedClockId` is a stored defaults key (spec § Persistence). Hidden when one clock is configured; remembered across launches; the "current clock" the Add tile menu is checked against.                                                                               |
| D4   | **Tile detail is a surface.** It opens in the panel's window like the settings and the History — a third branch in the surface switch, carrying the `TileKey` it was opened for. The panel stays one window with one width.                                                                     |
| D5   | **Removal confirms inline, and says what it takes.** "Remove Weather from Desk?" — because the settings are gone, and on a TC002 the tile's page leaves the knob cycle (empty-body delete, phase-3 A9). The confirmation names the clock so the user knows which one loses the tile.               |
| D6   | **"No clocks yet" is reachable.** `ClockStore.firstClock(orCreatingAt:)` loses its create branch — the phase-1 owe-list names phase 5 for it. A fresh install migrates nothing, writes no marker, and shows the empty state. An existing install that already stored a clock is unaffected.       |
| D7   | **The glyph answers for the selected clock only.** Offline is drawn from the selected clock's session; "any clock offline" would be permanent on a laptop that left the kitchen clock behind (spec § Behaviour). Weave with 4b's health wiring, whichever shape it lands in.                       |
| D8   | **A settings section leaves only after its migration step has landed.** `WeatherSettings` and `quietHoursSection` go in Task 12, and only because phase 4's steps moved the weather location and the quiet hours onto tiles (spec § Persistence — the row moves in the phase that stops the app writing its source key). If a step has not landed, the section stays and the task says so. |
| D9   | **Availability comes from `TileCatalogue`.** The menu renders reasons; it does not compute them. `TileCatalogue.availability(connector:on:)` is phase 4b's type; until its exact shape is on the tree, 5a's `AddTileMenuItem` carries a local `Availability` value and 5b maps one onto the other.  |
| D10  | **Old views move, never rewrite.** `DeviceStatusLine`, `DiscoveryStatusLine`, `BatteryLine`, `NextRunLine` move into their files as they are. `PanelWidth` and `ResizeBorder` are reused untouched. Moving tests beside them is all it may ever be.                                             |

## Impact signals

Measured on the integration tree (`pct-worktrees/int`, `feat/pixelclocktiles-int`),
2026-09-20, with `--follow` across the rename:

| File | Commits | Fix-like | Reading for this phase |
| --- | --- | --- | --- |
| `Sources/PixelClockTilesApp/AppModel.swift` | 40 | 13 (33%) | The hottest file, and lane 4b is editing it right now (D2). 5b keeps every task a separate commit and additive where it can be. |
| `Sources/PixelClockTilesApp/MenuPanel.swift` | 24 | 10 (42%) | The reason the file is being split at all. Tasks 2–5 only ever ADD files; Task 12 does the one edit that rewires `body`. |
| `Sources/PixelClockTilesApp/SettingsSheet.swift` | 14 | 0 | Low churn, but Task 12 removes two of its sections — the removals are exactly the parts phase 4's migration steps already moved. |
| `Sources/PixelClockTilesApp/App.swift` | 13 | 6 (46%) | Highest fix ratio in the app target. Task 11 touches the glyph only; the window and delegate plumbing stays untouched. |
| `Sources/PixelClockKit/Clocks/*`, `Tiles/*` | 1–2 | 0 | Young, single-owner, tested. 5a consumes them read-only; nothing in this plan edits a store. |

## File structure

```text
Sources/PixelClockTilesApp/
├── TileRowLine.swift                (Task 1, NEW — plain row text + badge)
├── AddTileMenuItem.swift            (Task 1, NEW — plain menu item + availability)
├── ClockSwitcher.swift              (Task 2, NEW)
├── ClockStatusBlock.swift           (Task 3, NEW — receives the status enums, moved)
├── TileRow.swift                    (Task 4, NEW)
├── AddTileMenu.swift                (Task 5, NEW)
├── TileDetail.swift                 (Task 6, NEW — incl. TilePolicyEditor)
├── ClocksSettings.swift             (Task 7, NEW)
├── MenuPanel.swift                  (Task 12 ONLY: body becomes the parts)
├── SettingsSheet.swift              (Task 12 ONLY: ClocksSettings in, two sections out)
├── App.swift                        (Task 11: glyph rule; Task 12: surface switch gains detail)
└── AppModel.swift                   (Tasks 8–11, one commit each, D2 weave)
Tests/PixelClockTilesAppTests/
├── TileRowLineTests.swift           (Task 1)
├── ClockSwitcherTests.swift         (Task 2)
├── ClockStatusBlockTests.swift      (Task 3)
├── TileRowTests.swift               (Task 4)
├── AddTileMenuTests.swift           (Task 5)
├── TileDetailTests.swift            (Task 6)
├── ClocksSettingsTests.swift        (Task 7)
├── PanelProjectionTests.swift       (Task 8)
├── TileActionTests.swift            (Task 9)
├── ClockActionTests.swift           (Task 10)
└── NoClocksTests.swift              (Task 11)
docs/HANDOFF.md                      (Task 13 appends)
```

## Contact points

- **Phase 1 (landed).** `ClockStore`, `TileStore`, `TileSettingsStore`,
  `ClockRecord`, `TileRecord`, the step markers. Task 11 removes
  `firstClock(orCreatingAt:)`'s create branch and decides the fresh-install
  behaviour of `ClockMigration` — the two items phase 1's owe-list assigns
  this phase.
- **Phase 2 (landed).** `NextRunLine` is the testing pattern Task 1 follows;
  `ConnectorRunning` is whatever 4b renames it to.
- **Phase 3b (landed).** `UlanziConnectorRunning`, `UlanziTileBoard`,
  `UlanziClockSession`. Its two stopgaps — `NoClockHost` and the `start()`
  guard keeping device loops off a TC002 — are phase 4's to replace; this plan
  presumes they are gone and its tasks name no use of them.
- **Phase 4 (in flight — 4b).** Sessions per clock, `TileKey`-keyed
  scheduling, `TileCatalogue.availability`, `TilePolicyRecord`'s Focus and
  hours keys, the keyed weather cache, the migration steps for the quiet
  hours, `weatherLocation` and the VPN lamps. Every `AppModel`-touching task
  here weaves with it (D2). If 4b has not landed `TileCatalogue` when Task 9
  runs, the menu maps from whatever availability source exists and the mapping
  is the seam D9 names.
- **Phase 4a (landed).** `TilePolicy`, `FocusRule`, `TileWindow`,
  `HourWindow`, `TileHold`, `PolicyGrid` (+overlap), `RefreshScale`,
  `TileDefaults`, `MacFocus`. Task 6's editor edits these values; it
  reinvents none of them.
- **Lane C (landed).** `ClaudeCodeSettings` in the general settings is
  untouched; Task 12 moves nothing around it. C1–C6 stay owed to the hardware.
- **The settled TC002 model.** One app per tile, the knob rotates, the Mac
  never does. UI copy that mentions removal says the page leaves the knob
  cycle; nothing in this plan offers a rotate control, and no task adds a
  `switchDiyApp` caller. The "Show on clock" action, if built, is its own
  later decision.

---

## Part 5a — views and plain types (parallel-safe)

No task in this part imports `AppModel`. Each builds against values it
declares, and each lands on a green tree in any order, in any lane.

### Task 0: Baseline

The phase assumes the integrated tree compiles and the suite is green before
the first RED.

**Files:**

- Read: `docs/HANDOFF.md` (§ 'How this branch finds defects')
- Read: the spec, § Menu bar UI and § Behaviour
- Unchanged: everything else

**Interfaces:**

- Consumes: phases 1–4a and C on the tree (`Sources/PixelClockKit/Tiles/`
  with `TilePolicy.swift`, `Sources/PixelClockKit/Clocks/ClockStore.swift`,
  `Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift` present)

- [ ] **Step 1: Confirm the substrate is present.**

Run:

```bash
test -f Sources/PixelClockKit/Tiles/TilePolicy.swift && test -f Sources/PixelClockKit/Clocks/ClockStore.swift && test -f Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift && test -f Sources/PixelClockTilesApp/MenuPanel.swift
```

Expected: no output. If any path is missing, stop — this is not the tree the
plan extends.

- [ ] **Step 2: Clean build, zero warnings.**

Run:

```bash
swift build -j 2 2>&1 | grep -i warning
```

Expected: no output.

- [ ] **Step 3: Full suite green; record N0.**

Run:

```bash
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass. Record the passed-count as `N0` — the Task 13 audit diffs
against it.

---

### Task 1: TileRowLine and AddTileMenuItem — the plain types

The spec's rule for this phase: text and availability are computed in plain
types and tested like `NextRunLine` is, so the views stay thin. Both types
land here, before any view needs them.

**Files:**

- Create: `Sources/PixelClockTilesApp/TileRowLine.swift`
- Create: `Sources/PixelClockTilesApp/AddTileMenuItem.swift`
- Create: `Tests/PixelClockTilesAppTests/TileRowLineTests.swift`

**Interfaces:**

- Produces: `TileRowLine` (`.drawn(name:result:hold:failing:)` → row text plus
  an optional badge), `TileRowLine.Badge` (`.paused`, `.heldByFocus`,
  `.silentHours`, `.failing`), `AddTileMenuItem`, `AddTileMenuItem.Availability`
  (`.available`, `.unavailable(reason: String)`)
- Consumes: `TileHold` (`PixelClockKit.Tiles`)

- [ ] **Step 1: RED — the badge answers why a tile is not running.**

```swift
// Tests/PixelClockTilesAppTests/TileRowLineTests.swift
@Suite struct TileRowLineTests {
    @Test func runningTileDrawsResultWithoutBadge() {
        let line = TileRowLine.drawn(name: "Weather", result: "12°C",
                                     hold: nil, failing: false)
        #expect(line.text == "Weather  12°C")
        #expect(line.badge == nil)
    }

    @Test func eachHoldDrawsItsBadge() {
        // TileHold.paused → .paused; .hours → .silentHours; .focus → .heldByFocus
    }

    @Test func failingOutranksAnEmptyResult() {
        // failing: true, result: nil → badge .failing, no invented result text
    }

    @Test func unavailableItemCarriesItsReason() {
        // .unavailable(reason: "already speaking through Kitchen") survives intact
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter TileRowLineTests
```

Expected: compile error — `TileRowLine` does not exist.

- [ ] **Step 2: GREEN — implement both types.**

Pure values, no SwiftUI import. `drawn` composes what the row shows from what
it is given and decides nothing about Focuses or hours. `TileHold` already
did that work; the line only names it.

Run:

```bash
swift test -j 2 --no-parallel --filter TileRowLineTests
```

Expected: pass.

- [ ] **Step 3: Mutation check.**

Flip the badge mapping (`.hours` → `.silentHours` to `.heldByFocus`). The hold
tests must fail; revert.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockTilesApp/TileRowLine.swift Sources/PixelClockTilesApp/AddTileMenuItem.swift Tests/PixelClockTilesAppTests/TileRowLineTests.swift
git commit -m "PixelClockTilesApp: TileRowLine and AddTileMenuItem, the panel's plain types"
```

---

### Task 2: ClockSwitcher — one segment per clock

**Files:**

- Create: `Sources/PixelClockTilesApp/ClockSwitcher.swift`
- Create: `Tests/PixelClockTilesAppTests/ClockSwitcherTests.swift`

**Interfaces:**

- Produces: `ClockSwitcher` — takes `clocks: [ClockSwitcher.Entry]` (id, name,
  model glyph), `selection: Binding<UUID>`; renders nothing when
  `clocks.count < 2`
- Consumes: nothing from the kit but `UUID`

- [ ] **Step 1: RED — hidden with one clock, one segment per clock.**

Test the two facts that must reach the screen, with the bitmap technique of
`PanelRenderingTests`: at two clocks every name is drawn; at one clock the
view is empty. A third test drives the binding: activating the "Kitchen"
segment writes Kitchen's id into the binding.

- [ ] **Step 2: GREEN — implement the switcher.**

A segmented picker over the entries. The model glyph (TC001 against TC002) is
text, not an asset. The panel has no image assets today and gains none here.

Run:

```bash
swift test -j 2 --no-parallel --filter ClockSwitcherTests
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/ClockSwitcher.swift Tests/PixelClockTilesAppTests/ClockSwitcherTests.swift
git commit -m "PixelClockTilesApp: ClockSwitcher, one segment per clock"
```

---

### Task 3: ClockStatusBlock — the selected clock's status, moved

`DeviceStatusLine`, `DiscoveryStatusLine` and `BatteryLine` exist and are
tested. This task moves them into the file whose section they will serve, and
wraps them in the block the panel will draw. The move is all it is (D10).

**Files:**

- Create: `Sources/PixelClockTilesApp/ClockStatusBlock.swift`
- Create: `Tests/PixelClockTilesAppTests/ClockStatusBlockTests.swift`
- Move (in Task 12, not here): the enums out of `MenuPanel.swift`

**Interfaces:**

- Produces: `ClockStatusBlock` — takes the status inputs as values (online,
  address, battery text or nil, discovery state or nil); draws the battery
  line only when one is handed in
- Consumes: `DeviceStatusLine`, `DiscoveryStatusLine`, `BatteryLine` (moved in
  Task 12)

- [ ] **Step 1: RED — the block is a battery-less shape for a TC002.**

Render two states: an AWTRIX clock online with a battery reading, and a TC002
online. The first draws the percentage; the second draws none: the cell is
absent, not a placeholder. This is already the measured rule (the TC002 has a
3600 mAh battery the stock API cannot read); the test pins it at the new
block's seam so the rule survives the split.

- [ ] **Step 2: GREEN — implement the block.**

Composition over the existing enums. No new line text is invented here.

Run:

```bash
swift test -j 2 --no-parallel --filter ClockStatusBlockTests
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/ClockStatusBlock.swift Tests/PixelClockTilesAppTests/ClockStatusBlockTests.swift
git commit -m "PixelClockTilesApp: ClockStatusBlock around the existing status lines"
```

---

### Task 4: TileRow — result, badge, and the three actions

**Files:**

- Create: `Sources/PixelClockTilesApp/TileRow.swift`
- Create: `Tests/PixelClockTilesAppTests/TileRowTests.swift`

**Interfaces:**

- Produces: `TileRow`, `TileRowValue` (name, result `String?`, line:
  `TileRowLine`, `isAmbient: Bool`, `onRun`, `onDetail`, `onRemove` closures);
  the remove button confirms inline before calling `onRemove`
- Consumes: `TileRowLine` (Task 1)

- [ ] **Step 1: RED — the row and its inline confirmation.**

Bitmap tests: a row draws name, result and badge on one line; an ambient tile
draws no `▶`; the confirmation state draws "Remove Weather from Desk?" in
place of the row, and cancelling puts the row back. The confirm text comes
from the value; the view does not know a clock's name otherwise.

- [ ] **Step 2: GREEN — implement the row.**

Removing loses the tile's settings and, on a TC002, takes its page off the
clock; that is why the confirm is inline and names the clock (D5). No
system alert: the panel is a small window and the question is one row tall.

Run:

```bash
swift test -j 2 --no-parallel --filter TileRowTests
```

Expected: pass.

- [ ] **Step 3: Mutation check.**

Delete the `.paused` badge branch from the row. The Task 1 badge test still
passes (the type is pure); the row test must fail — that is the difference
the split buys. Revert.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockTilesApp/TileRow.swift Tests/PixelClockTilesAppTests/TileRowTests.swift
git commit -m "PixelClockTilesApp: TileRow with the inline removal confirmation"
```

---

### Task 5: AddTileMenu — availability beside every disabled entry

**Files:**

- Create: `Sources/PixelClockTilesApp/AddTileMenu.swift`
- Create: `Tests/PixelClockTilesAppTests/AddTileMenuTests.swift`

**Interfaces:**

- Produces: `AddTileMenu` — takes `[AddTileMenuItem]`; an unavailable item is
  disabled with its reason drawn beside it
- Consumes: `AddTileMenuItem` (Task 1)

- [ ] **Step 1: RED — the reason is on the menu, not in a tooltip.**

Render a menu with one available and one unavailable item. The unavailable
one is disabled and its reason ("not supported on TC002", "already speaking
through Kitchen") is drawn. The spec puts the reason beside the entry:
a tooltip on a disabled control never fires.

- [ ] **Step 2: GREEN — implement the menu.**

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/AddTileMenu.swift Tests/PixelClockTilesAppTests/AddTileMenuTests.swift
git commit -m "PixelClockTilesApp: AddTileMenu with availability reasons"
```

---

### Task 6: TileDetail — the shared policy editor and the connector's block

The one surface where a tile's whole behaviour is visible at once: the shared
`TilePolicy` editor on top, the connector's own block under it. The editor
edits `TilePolicy` values. The kit types from 4a already carry the rules, so
nothing here decides when a tile runs.

**Files:**

- Create: `Sources/PixelClockTilesApp/TileDetail.swift` (the surface and
  `TilePolicyEditor`)
- Create: `Tests/PixelClockTilesAppTests/TileDetailTests.swift`
- Reused unchanged: `LocationField.swift`, `HistoryMenu.swift`,
  `PanelWidth.swift`

**Interfaces:**

- Produces: `TileDetail` — takes the tile's name, its `TilePolicy`, a
  connector block (any view), and `onPolicy: (TilePolicy) -> Void` plus
  `onBack`; header reads "← Weather · Desk"
- Produces: `TilePolicyEditor` — paused toggle; refresh slider over
  `RefreshScale.steps` (the stored seconds are snapped when read, written only
  when the slider moved, the `TileSettingsStore` rule); "works in" checkboxes
  over `MacFocus` cases minus `.unknown`, with the when-unknown picker (run /
  hold) for everything else; hours picker over `.always` / `.quiet(HourWindow)`
  / `.active(HourWindow)`
- Consumes: `TilePolicy`, `FocusRule`, `TileWindow`, `HourWindow`,
  `MacFocus`, `RefreshScale` (all 4a)

- [ ] **Step 1: RED — the editor round-trips a policy.**

Value-level tests through the editor's binding: ticking "Work" off adds it to
`silencedIn`; switching hours to quiet keeps the window; the slider's position
maps through `RefreshScale` in both directions, and a stored 45 s (a value the
scale cannot show) reads as the snapped step without being written back. Two
bitmap tests pin the header ("← Weather · Desk") and the when-unknown picker.

- [ ] **Step 2: RED — each connector block renders on its own tile.**

Weather carries the location field; the anecdote tile carries the History
button (a closure; opening the existing `HistoryMenu` surface is Task 12's
switch); the VPN tile carries the VPN preset picker, the lamp slot, the eight
palette colours plus a `ColorPicker`, and the down behaviour (off / blink).
The palette is the spec's saturated eight, in code, with names.

- [ ] **Step 3: GREEN — implement the surface.**

- [ ] **Step 4: Mutation check.**

Invert the works-in checkbox polarity (a tick silences instead of allows).
The round-trip tests must fail; revert.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PixelClockTilesApp/TileDetail.swift Tests/PixelClockTilesAppTests/TileDetailTests.swift
git commit -m "PixelClockTilesApp: TileDetail with the shared TilePolicy editor"
```

---

### Task 7: ClocksSettings — the Clocks section of the general settings

**Files:**

- Create: `Sources/PixelClockTilesApp/ClocksSettings.swift`
- Create: `Tests/PixelClockTilesAppTests/ClocksSettingsTests.swift`

**Interfaces:**

- Produces: `ClocksSettings`, `ClockListEntry` (id, name, model, address,
  status text), `DiscoveredClock` (name, model, address) — the section takes
  entries, discovered clocks, and closures (rename, remove, add discovered,
  add by address)
- Consumes: nothing from `AppModel`; the dual-probe and UDP discovery are
  Task 10's to wire

- [ ] **Step 1: RED — the list, the confirmation, the two ways in.**

Bitmap and value tests: each entry draws name, model, address and status;
removing confirms ("Remove Kitchen? Every tile on it goes with it."); an
empty list offers add-from-discovery and add-by-address and nothing else.

- [ ] **Step 2: GREEN — implement the section.**

The removal copy says what custody will do, because it is irreversible from
this surface: every tile on the clock goes through its session's teardown.

Run:

```bash
swift test -j 2 --no-parallel --filter ClocksSettingsTests
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/ClocksSettings.swift Tests/PixelClockTilesAppTests/ClocksSettingsTests.swift
git commit -m "PixelClockTilesApp: ClocksSettings, the Clocks section of the general settings"
```

---

## Part 5b — `AppModel` and the switch-over (presumes phases 1–4 + C)

Every task in this part starts the same way:

> **Merge `feat/pixelclocktiles-int` first.** Lane 4b is rewiring `AppModel`
> as this plan is written: battery healths, init parameters, the poll
> rewrite, `scheduleHold`. Weave this task's edits with 4b's wiring and keep
> both intents: the steps below say what becomes true, never which field
> holds it. If 4b moved the thing a step names, follow 4b's shape and keep
> this task's outcome.

### Task 8: AppModel — the per-clock projection and the selection

**Files:**

- Modify: `Sources/PixelClockTilesApp/AppModel.swift`
- Create: `Tests/PixelClockTilesAppTests/PanelProjectionTests.swift`

**Interfaces:**

- Produces: `selectedClockId` (published, persisted under the spec's key),
  the projection the panel consumes, per selected clock: the status inputs of
  `ClockStatusBlock`, `[TileRowValue]` for its tiles, `[AddTileMenuItem]` from
  the availability source, the open/close of the detail surface carrying a
  `TileKey`
- Consumes: the sessions-per-clock spine 4b landed, `TileRowLine`,
  `AddTileMenuItem`, `TileRowValue` (Tasks 1, 4)

- [ ] **Step 1: RED — two clocks, two projections.**

Store two clocks with different tiles; switch the selection; assert the row
values and status inputs name the selected clock's tiles only, and that the
stored key survives a fresh `AppModel`. A tile held by Focus (its `TileHold`
from the policy, however 4b exposes the current `MacFocus` and hour) draws the
focus badge.

- [ ] **Step 2: GREEN — the projection.**

Additive: new published inputs and a switch that reads them; the polling and
scheduling spine 4b owns is not restructured here. Whatever 4b renamed or
regrouped, the projection reads through it.

Run:

```bash
swift test -j 2 --no-parallel --filter PanelProjectionTests
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/PanelProjectionTests.swift
git commit -m "PixelClockTilesApp: per-clock panel projection and the persisted selection"
```

---

### Task 9: Tile actions — add, run now, pause, remove

**Files:**

- Modify: `Sources/PixelClockTilesApp/AppModel.swift`
- Create: `Tests/PixelClockTilesAppTests/TileActionTests.swift`

**Interfaces:**

- Produces: `addTile(connector:on:)`, `runNow(tile:)`, `setPaused(_:tile:)`,
  `removeTile(_:)` — the closures `TileRow` and `AddTileMenu` carry
- Consumes: `TileDefaults` (4a), the per-model session (4b), `TileStore`

- [ ] **Step 1: RED — the four actions against a scripted session.**

Add copies the connector's defaults into a new `TileRecord` and refuses a
second tile of a `.single` connector on the same clock. Run now delivers once
through the tile's session. Pausing on a TC002 marks the tile idle: its page
stays, held by the idle frame, never deleted. Pausing on an AWTRIX
behaves exactly as disabling does today. Removing deletes — on a TC002 the
empty-body POST (phase-3 A9), on an AWTRIX `removeApp` — and the row's
confirmation (Task 4) is the only thing that stood in front of it.

- [ ] **Step 2: GREEN — the actions.**

The custody interactions already exist on the sessions; this task routes the
UI's intent to them and writes nothing new about custody.

Run:

```bash
swift test -j 2 --no-parallel --filter TileActionTests
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass.

- [ ] **Step 3: Mutation check.**

Make `removeTile` post `{}` instead of the empty body on the TC002 path. The
remove test must fail — the measured contract is the empty body, `{}` does not
delete. Revert.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/TileActionTests.swift
git commit -m "PixelClockTilesApp: tile actions routed through the per-model sessions"
```

---

### Task 10: Clock actions — add, rename, remove

**Files:**

- Modify: `Sources/PixelClockTilesApp/AppModel.swift`
- Create: `Tests/PixelClockTilesAppTests/ClockActionTests.swift`

**Interfaces:**

- Produces: `addClock(from: DiscoveredClock)`, `addClock(address: String)`,
  `renameClock(_:to:)`, `removeClock(_:)` — the closures `ClocksSettings`
  carries
- Consumes: `ClockStore`, `ClockMigration`'s markers, the UDP listener and the
  dual probe (`UlanziDiscovery`), the Bonjour browse

- [ ] **Step 1: RED — detection decides the model, removal tears down.**

Adding by address runs `GET /api/stats` and `/getBase` concurrently and the
model is whichever response decodes — status codes are not trusted (the TC002
answers the AWTRIX path with 301). Adding from discovery takes the merged
browse + broadcast list. Renaming writes through `ClockStore.update` and
touches nothing else. Removing confirms first, then takes every tile off the
clock through its session's teardown and drops the record.

- [ ] **Step 2: GREEN — the actions.**

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/ClockActionTests.swift
git commit -m "PixelClockTilesApp: clock add, rename and remove"
```

---

### Task 11: The glyph, the empty state, and the retired launch fallback

**Files:**

- Modify: `Sources/PixelClockTilesApp/App.swift` (glyph only)
- Modify: `Sources/PixelClockTilesApp/AppModel.swift`
- Modify: `Sources/PixelClockKit/Clocks/ClockStore.swift`
- Modify: `Sources/PixelClockTilesApp/ClockMigration.swift`
- Create: `Tests/PixelClockTilesAppTests/NoClocksTests.swift`

**Interfaces:**

- Produces: the glyph rule (offline drawn from the selected clock), the
  no-clocks panel ("No clocks yet", "Add clock…" → the Clocks section),
  `ClockStore.firstClock() -> ClockRecord?` (the create branch gone),
  `ClockMigration` on a fresh install: writes nothing, marks nothing
- Consumes: the panel from Task 12's shape — this task and Task 12 land as a
  pair on one branch, in this order, so the empty state has somewhere to point

- [ ] **Step 1: RED — the empty state is reachable and the fallback is gone.**

A fresh defaults domain boots to the no-clocks panel and stores no clock —
`firstClock()` returns nil, no record appears, no marker is written. An
install with a stored clock is unaffected. The glyph test: two clocks, the
kitchen one offline, the desk one selected → the glyph draws online; select
the kitchen one → it draws offline.

- [ ] **Step 2: GREEN — remove the branch, answer the empty state.**

Phase 1's owe-list assigned exactly this to phase 5: the branch goes once "No
clocks yet" is a state the user can reach. `ClockMigration` on a fresh install
decides D6: it writes nothing and leaves the decision to the user, because a
clock created at a guessed address for nobody is the bug the branch was.

Run:

```bash
swift test -j 2 --no-parallel --filter NoClocksTests
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/App.swift Sources/PixelClockTilesApp/AppModel.swift Sources/PixelClockKit/Clocks/ClockStore.swift Sources/PixelClockTilesApp/ClockMigration.swift Tests/PixelClockTilesAppTests/NoClocksTests.swift
git commit -m "PixelClockTilesApp: the no-clocks state, and the launch fallback retired"
```

---

### Task 12: The switch-over — MenuPanel assembled from the parts

The one task that edits `MenuPanel.swift` and `SettingsSheet.swift` (D8, and
the part-5a constraint). Everything before this landed as files with tests and
no callers; this task connects them.

**Files:**

- Modify: `Sources/PixelClockTilesApp/MenuPanel.swift` — `body` becomes
  ClockSwitcher, ClockStatusBlock, the tile rows, AddTileMenu and `lastRow`;
  the surface switch gains the detail branch carrying its `TileKey`; the moved
  enums (`DeviceStatusLine`, `DiscoveryStatusLine`, `BatteryLine`) leave for
  `ClockStatusBlock.swift`; the moved tests follow them
- Modify: `Sources/PixelClockTilesApp/SettingsSheet.swift` — `ClocksSettings`
  replaces `deviceHostSection`; `WeatherSettings` and `quietHoursSection` are
  removed (D8: only because phase 4's migration steps landed); the
  microphones, login-item, Claude Code and icon sections stay as they are
- Modify: `Tests/PixelClockTilesAppTests/PanelRenderingTests.swift` — the
  rendered states the new body has

**Interfaces:**

- Consumes: everything 5a built, everything Tasks 8–11 published

- [ ] **Step 1: RED — the panel draws the assembled shape.**

Update the rendering tests first: one clock hides the switcher; two clocks
show it; a tile's badge and its inline confirmation draw; the Add tile menu
carries a reason; the settings sheet shows the Clocks section where the
address field was and no weather or quiet-hours section.

- [ ] **Step 2: GREEN — rewire, move, delete.**

Move the enums and their tests; replace the sections; delete
`WeatherSettings` and `DeviceHostField` with their tests. Nothing else in the
two files is rewritten — the diff should read as connection, movement and
deletion.

Run:

```bash
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/MenuPanel.swift Sources/PixelClockTilesApp/SettingsSheet.swift Sources/PixelClockTilesApp/ClockStatusBlock.swift Tests/PixelClockTilesAppTests/PanelRenderingTests.swift Tests/PixelClockTilesAppTests/ClockStatusBlockTests.swift
git commit -m "PixelClockTilesApp: MenuPanel assembled from its parts, settings reorganized"
```

---

### Task 13: Audit and hand-off

The phase-3 close-out shape: assert nothing regressed, then write down what
only a person at the hardware can settle.

**Files:**

- Read: `docs/HANDOFF.md`
- Modify: `docs/HANDOFF.md` (append the phase-5 section)

- [ ] **Step 1: The audits.**

Run:

```bash
grep -rn "switchDiyApp" Sources/ | grep -v "^Binary"
grep -rn '"{}"' Sources/PixelClockKit/Ulanzi/ Sources/PixelClockTilesApp/ || true
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
swift test -j 2 --no-parallel --filter nothingButTheAnecdotesEverPutsSoundInTheRoom
swift build -j 2 2>&1 | grep -i warning
```

Expected: `switchDiyApp` — no matches (D3 still holds). No `{}` JSON delete
anywhere — the empty body is the only delete. Suite passes at N0 or above with
the new tests counted; zero warnings.

Also grep the part-5a constraint was honoured in history: no commit between
Tasks 1–11 touched `MenuPanel.swift` or `SettingsSheet.swift` except Task 12's.

- [ ] **Step 2: Append the phase-5 section to HANDOFF.**

What the phase leaves, and what only a person at the hardware can settle:

1. Both clocks on the desk: the switcher, a tile row per clock, and the
   battery line appearing on the AWTRIX and never on the TC002.
2. Removing a TC002 tile with the knob parked on its page — the deleted-page
   effect (E4) the user now reaches from the panel.
3. The policy editor against the real Focus modes: the badge flips when Work
   is entered and left.
4. The empty state on a fresh defaults domain, and the migration on an
   install upgraded across the phase.

- [ ] **Step 3: Commit.**

```bash
git add docs/HANDOFF.md
git commit -m "docs: what phase 5 leaves for the hardware"
```
