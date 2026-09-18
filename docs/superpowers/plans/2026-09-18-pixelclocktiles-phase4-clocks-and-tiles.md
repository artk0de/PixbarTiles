# PixelClockTiles Phase 4 — Several Clocks and Tiles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `dinopowers:executing-plans` (it wraps `superpowers:executing-plans` and `superpowers:subagent-driven-development`) to carry this plan out task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive every clock in `clocks` at once, one session each, and give every tile a `TilePolicy` of its own in place of the app-wide `FocusGate`. VPN lamps become tiles that share a lamp by taking turns.

**Architecture:** The policy is pure value types in `PixelClockKit` (`MacFocus`, `HourWindow`, `RefreshScale`, `FocusRule`, `TileWindow`, `TilePolicy`, `PolicyGrid`). The app target keeps what reads macOS: resolving `INFocusStatusCenter` and the Do Not Disturb database into a `MacFocus`, the process table, and the schedule. `AppModel` holds a session per clock, keys every timer by `TileKey`, and asks each tile's own policy what holds it.

**Tech Stack:** Swift 6.3.3, SwiftPM tools 6.0, macOS 14 floor, `swift-testing`, Swift 6 strict concurrency. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md`: § Tile, § TilePolicy, § Adding a tile, § VPN tiles, § Connectors and faces, § Error handling, and the Phase 4 row.

**House format and Global Constraints:** `docs/superpowers/plans/2026-08-17-awtrix-connectors.md`. Its Global Constraints still bind and are not repeated here, except for one addition below.

**Discipline:** `docs/HANDOFF.md` § "How this branch finds defects". Every guard gets a mutation, **one site at a time**. After adding a guard, re-run the mutations of the guards it sits in front of. The mutation tables of A1–A11, of the Part B kit code and of the five migration steps were run in scratch packages before this plan was written, and every mutation died. The wiring tasks' tables (B3, B7's app edits, B13–B19) are for the executor to run.

---

## How this plan is split

| Part | Runs | Depends on |
| --- | --- | --- |
| **A (4a)** — Tasks A1–A11 | in parallel with Phases 1, 2 and 3a, right after the rename | only code that exists after Phase 0 |
| **B (4b)** — Tasks B1–B21 | after Phases 1, 2 and 3 have landed | Part A, and the Phase 1/2/3 symbols in [Re-verify before executing](#re-verify-before-executing) |

**A deliberate exception to "a type lands with its caller".** The spec says a type lands in the phase that first reads it. Every Part A type gets its production caller in Part B: the stored policy's mapping (B2), the migration steps (B7, B14, B15, B16, B18), the schedule (B16) and the lamps (B18). The split trades that rule for parallelism, as the spec's § Phases now records for every Part A. The program merges Part A, Phases 1–3 and Part B before anything reaches `master`, so no caller-less type ever ships. Two Part A types do get a production caller inside Part A: `MacFocus.modeIdentifier` (A1, through `DoNotDisturbDatabase.silencing`) and `HourWindow` (A2, through `QuietWindow`).

**Phase 1 owns the stored form. Part A owns the domain form.** Phase 1 declares `ClockModel`, `ClockRecord`, `ClockStore`, `TileKey`, `TileRecord`, `TileStore`, `TileSettingsStore` and `TilePolicyRecord`, and Part A declares none of them. The persisted policy is Phase 1's `TilePolicyRecord { isPaused, refreshSeconds: Int }` under `policy`. Part A's `TilePolicy` is the evaluated form, which knows how to answer "does this tile run now". Part A gives `FocusRule` and `TileWindow` their JSON shapes (A7), because B2 adds them to `TilePolicyRecord` as the optional keys `focus` and `window`. The mapping between the two forms is explicit, in B2.

## Global Constraints — addition for this phase

- The executor makes **no network calls to the clock** at `192.168.1.72`. It is live and in use. Everything here is tested against doubles.
- New names are checked against Apple's frameworks before they are used. `FocusState` was not, and it collides (see decision 1).

## Decisions this plan takes, and corrections to the spec

Each one is small. Each would otherwise be re-decided by whoever hits it first.

| # | Spec says | This plan does | Why |
| --- | --- | --- | --- |
| 1 | `FocusState` | **`MacFocus`** | SwiftUI declares `FocusState`. Verified in a scratch package: a file importing SwiftUI and the kit fails with `'FocusState' is ambiguous for type lookup`, and `Kit.FocusState` fails with `'FocusState' is not a member type of enum 'Kit.Kit'` because the kit's namespace enum shadows its module. Every Phase 5 view file would hit it. |
| 2 | case `.none` | **`.noFocus`** | Verified: `if last == .none` on a `MacFocus?` warns `assuming you mean 'Optional<…>.none'`. The branch builds with zero warnings, and `ActiveFocusMode.noFocus` already made this choice for this reason. |
| 3 | availability returns `.available` or `.unavailable(reason)` | a third case, **`.notListed`** | Rule 2 says a `.single` connector already on the clock is "not listed", which neither case can express. |
| 4 | zero-length `HourWindow` means "no window" | an empty window **restricts nothing**, for `.quiet` **and** `.active` | Read as "no working hours", `.active` of zero length is a tile that never runs again because a picker landed on its own start. That is `QuietWindow`'s own zero-length argument. |
| 5 | `focus.silencedIn: Set<FocusState>` and `whenUnknown` | `whenUnknown` is the **only** thing that decides `.unknown`; `.unknown` in the set is inert | The two fields overlap, and the editor shows five boxes and a menu. A sixth, invisible box that overruled the menu would be state nobody can see. |
| 6 | refresh "snapped to the nearest scale value" | a tie takes the **longer** step | Only a value nobody chose on the slider can tie. The longer step asks less of a clock and of a free API. |
| 7 | the 144-cell grid | a paused policy's grid is **empty**, and unpausing is a save that meets the lamp check | The grid answers "does the tile run here". A paused tile claims no lamp. |
| 8 | "Two VPN tiles on the same slot whose grids intersect are refused" | the refusal names the **existing** tile first: "Pritunl and WireGuard both claim the middle lamp: Work, 10:00–19:00" | That matches the spec's example, where Pritunl is the migrated tile. |
| 9 | the VPN row: "a lamp write through `IndicatorCustody`, not a scene" | `VPNConnector` is **not a `Connector`**. It has `read(config:)` and a lamp face, `signal(for:)`, and `TileCandidate(_ vpn:)` offers it on AWTRIX clocks as `.perKey`. The reading carries its tile config (`VPNReading{isUp, lamp}`) | `Connector.awtrixFace` is required and draws an `AwtrixDelivery` (Phase 2 D6). A lamp is not a delivery, so a lamp connector cannot satisfy the protocol honestly. It does not have to: nothing else in the scene pipeline reads it. `awtrixFace` therefore stays required. The spec's "becomes optional in the phase that adds the first connector without one" is not triggered here. |
| 10 | "no flash of the wrong colour" (hardware check 2) | each lamp's owner is resolved **per clock, per slot, before anything is written** (`LampBoard`) | A per-tile retract followed by a per-tile show goes old colour → off → new colour. Resolving first goes old → new in one write. |
| 11 | `FocusState` resolution table | lives in the **app target** (`MacFocusResolution.swift`), not the kit | Its inputs, `FocusAccess` and `ActiveFocusMode`, are the app's model of macOS and stay where `FocusStatusReading` is. Moving them would touch `FocusGate.swift` more than Part A needs to. |
| 12 | `associatedtype Config` on `Connector`, `read(config:)` | **no `Config` on the protocol.** A tile's settings are `TileRecord.config: TileConfig?`, a closed enum (`.weather(Coordinates)`, `.vpn(VPNTileConfig)`). They reach a connector through the connector each clock's session is built with (B7, B13): the weather connector of a clock reads its location from that clock's weather tile. `WeatherConnector` already takes its location as a closure | Phase 2 made `read()` take no argument and moved about fifty tests onto it (D10, D7). An associated type would thread a `NoConfig` through Claude and the anecdotes, and rename every one of those `read()` calls, for one reader. The spec's own ClockSession paragraph already says a tile becomes a program "with `read` and the face closed over", and closing over the config belongs in the same step. |
| 13 | `TilePolicy` is stored | **`TilePolicyRecord` (Phase 1) is stored. `TilePolicy` is not `Codable`.** B2 adds `focus: FocusRule?` and `window: TileWindow?` to the record. A key absent from a record written before Phase 4 reads as the connector's defaults row | This is the coordinator's reconciliation with Phase 1 (its D2). One stored form, one evaluated form, one explicit mapping. |
| 14 | the session holds "backoff counts by `TileKey`"; Phase 2 D2 expects the chain to become generic over `TileKey` | **the session and `DeliveryChain` stay keyed by connector id, and `ConnectorRunning` keeps its name.** `AppModel` routes a `TileKey` to the session of `key.clockId` and calls it with `key.connectorId` | A session is one clock, and a clock carries one tile per scene connector (`.single`). The VPN, the one `.perKey` connector, never goes through a session. Inside a session a connector id already *is* a tile key, so re-keying would rename 53 moved session tests and every host double for no change in behaviour. Phase 2 D1 left the rename to Phase 4, and Phase 4 declines it with this reason. |

## Persisted shapes (reconciled with Phase 1)

Phase 1 stores `tiles` as `[{"key":{"clockId","connectorId","instance"},"policy":{"isPaused","refreshSeconds"},"lastDeliveredAt"?}]`. Part B adds optional keys only, so every record Phase 1 wrote still decodes. Tests pin each shape byte for byte (A7, B2, B5, B6).

A tile's `policy`, written from Phase 4 on (B2), with keys shown sorted:

```json
{"focus":{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"},
 "isPaused":false,"refreshSeconds":1800,
 "window":{"endHour":8,"kind":"quiet","startHour":23}}
```

- `focus` and `window` are **optional**. When a record lacks one (every record Phase 1 wrote), it reads as that connector's `TileDefaults` row. From Phase 4 on, a saved record always writes both.
- `silencedIn` is written in `MacFocus` declaration order, whatever order the set holds, so one policy is always the same bytes. `MacFocus` raw values: `noFocus`, `work`, `personal`, `doNotDisturb`, `sleep`, `unknown`. `whenUnknown`: `run` | `hold`.
- `window`: `{"kind":"always"}`, `{"kind":"quiet","startHour":H,"endHour":H}` or `{"kind":"active",…}`. Hours are read round the clock (24 → 0).
- `refreshSeconds` is kept as stored and snapped only when read (`TilePolicy.refresh`).

A tile's `config`, an optional key beside `policy` (B5, B6), with one key naming the connector:

```json
{"weather":{"latitude":55.7558,"longitude":37.6173}}
{"vpn":{"slot":"top","upColour":"#90EE90","vpn":"pritunl","whenDown":{"colour":"#FF0000","kind":"blink"}}}
{"vpn":{"slot":"bottom","upColour":"#A855F7","vpn":"amnezia","whenDown":{"kind":"off"}}}
```

VPN tiles use the instance ids `pritunl` and `amnezia`. The migrated VPN tiles (B18) write their `focus` explicitly with `"whenUnknown":"hold"`, so they never fall back to the VPN defaults row, which says `run`.

Migration markers Part B adds after Phase 1's `migration.clocks` and `migration.tiles`: `migration.weatherLocation` (B7), `migration.batteryHistory` (B14), `migration.borrowedOverlay` (B15), `migration.quietHours` (B16) and `migration.vpnTiles` (B18). Each lands in the commit that stops the app writing its source key. Each is its own step: marker last, old keys only read, second run a no-op.

## Impact enrichment (dinopowers:writing-plans, Step 2–3)

The tea-rags index for this repository is stale. It carries codegraph drift, every `fanIn` reads 0, and only `AppModel.swift` came back for the affected set. So the signals below come from `git log` on `feat/pixelclocktiles`. That fallback is sanctioned by the parent for this repository. Every file has one author (artk0de, 100%), so ownership routes no review.

| File (old path) | Commits | Fix commits | Last change | Note |
| --- | --- | --- | --- | --- |
| `Sources/AwtrixConnectorsApp/AppModel.swift` | 31 | 13 (42%) | 9 days | Composition root, 1,948 lines. Every Part B wiring task lands here. **High blast radius**, so each wiring task keeps to one concern |
| `Sources/AwtrixConnectorsApp/FocusGate.swift` | 4 | 2 | 4 weeks | Part A's only edit to an existing file. Part B deletes most of it |
| `Tests/AwtrixConnectorsAppTests/FocusGateTests.swift` | 4 | 3 | 4 weeks | 36 tests. Ported, not rewritten (B16, B20) |
| `Tests/AwtrixConnectorsAppTests/Doubles.swift` | 24 | 8 | — | Shared doubles. `testModel` gains `clocks:`, `tiles:` and `sessions:` in B13 |
| `Tests/AwtrixConnectorsAppTests/AppModelTests.swift` | 21 | 10 | — | Ported mechanically in B16 |
| `Sources/AwtrixKit/Scheduling/ConnectorHost.swift` | 11 | 3 | 4 weeks | Becomes `DeliveryChain` + `AwtrixClockSession` in Phase 2. Kept as is; one per clock from B13 |
| `Sources/AwtrixKit/Connectors/Connector.swift` | 11 | 2 | 4 weeks | Reshaped by Phase 2. B3 adds one requirement |
| `Sources/AwtrixConnectorsApp/SettingsSheet.swift` | 11 | 0 | — | B16 removes the quiet-hours pickers |
| `Sources/AwtrixKit/Scheduling/ConnectorSettings.swift` | 3 | 1 | 4 weeks | Read by Phase 1's migration through `RefreshScale.seconds(migratingIntervalPosition:)` |
| `Sources/AwtrixKit/Weather/OpenMeteoSource.swift` | 2 | 0 | 4 weeks | B1 |
| `ClaudeFocusAudience.swift`, `FocusGatedConnector.swift`, `VPNIndicatorPolicy.swift`, `VPNLampDisplay.swift`, `VPNPresence.swift`, `IntervalScale.swift`, `DeviceIndicator.swift`, `BatteryAlert.swift`, `QuitBudget.swift`, `BorrowedOverlayStore.swift`, `BatteryHistoryStore.swift`, `LocationField.swift` | 1–2 each | 0–1 | 3–5 weeks | Stable. Replaced (B17, B18) or keyed per clock (B14, B15) |

**Coordinated change candidates.** `FocusGate.swift`, `ClaudeFocusAudience.swift`, `FocusGatedConnector.swift` and `VPNIndicatorPolicy.swift` form one decision spread over four files, so Part B retires them in the order their replacements land (B16 → B17 → B18 → B20) and never all at once. The five migration steps (B7, B14, B15, B16, B18) each land in the commit that stops the app writing their source key, as Phase 1's D3 requires.

**Proven templates (Step 3.5).** `extract-project-patterns` has nothing to rank against a stale index. Each task names its template by hand instead: the existing file whose shape it follows.

## Contact points with parallel lanes

| Lane | What it must know from this plan | What this plan assumes of it |
| --- | --- | --- |
| **Phase 0 — rename** | Part A writes only under the new paths. | `Sources/PixelClockKit/`, module `PixelClockKit`, `Sources/PixelClockTilesApp/`, `Tests/PixelClockKitTests/`, `Tests/PixelClockTilesAppTests/`, test target dependencies renamed to match. `FocusGate.swift` is at `Sources/PixelClockTilesApp/FocusGate.swift`. If the kit's `public enum AwtrixKit` becomes `enum PixelClockKit`, module qualification of kit names is impossible, which is one more reason for decision 1. |
| **Phase 1 — domain and persistence** (plan: `…/2026-09-18-pixelclocktiles-phase1-domain-persistence.md`) | Part A declares none of `ClockModel`, `ClockRecord`, `ClockStore`, `TileKey`, `TileRecord`, `TileStore`, `TileSettingsStore` or `TilePolicyRecord`. Its names (`MacFocus`, `HourWindow`, `RefreshScale`, `FocusRule`, `TileWindow`, `TileHold`, `TilePolicy`, `TileDefaults`, `PolicyGrid`) collide with nothing Phase 1 declares. `RefreshScale.seconds(migratingIntervalPosition:)` computes exactly what Phase 1's `TileMigration` stores (`Int(ConnectorSettings.interval)`, the same `IntervalScale` path), so the two agree without either calling the other. Part B owns the rows Phase 1 moved out (its D3): `weatherLocation`, quiet hours and the VPN lamps (B7, B16, B18), and `batteryHistory` and `borrowedOverlay` (B14, B15), because Phase 4 is where health and custody become per clock. **B20 deletes `QuietWindow`**, and B16's migration step reads `quietStartHour` and `quietEndHour` itself for that reason. | `TileRecord` and `TilePolicyRecord` as Phase 1 declares them (quoted in the re-verify table). Part B adds optional fields only: `policy.focus`, `policy.window` and `config`. Phase 1's pinned shape tests keep passing. The schedule reads `TileStore` directly from B16, as Phase 1's "What later phases inherit" expects. `TileSettingsStore` stays, but only as each session's `SettingsStore` (B13): the session's pause guard reads it, and nothing else does. |
| **Phase 2 — ports and AWTRIX parity** (plan: `…/2026-09-18-pixelclocktiles-phase2-ports-awtrix-parity.md`) | Part A edits `FocusGate.swift` in three places (A1, A2) and nothing else that exists. Phase 2 does not touch that file, per its own contact table. | `ConnectorRunning` (app, keyed by connector id), `AwtrixClockSession` with `nonisolated let indicators: IndicatorCustody`, `IndicatorCustody.show(_:on:)`, `AwtrixFace<Reading>.draw(_:) -> AwtrixDelivery`, `Connector.read()` and a required `awtrixFace`, `produce()`, `DeliveryChain` keyed by `String`, health still in `AppModel`, `VPNLampDisplay(indicators:)`. Of what Phase 2 leaves for later, Phase 4 moves health per clock (B14), deletes `VPNLampDisplay` and makes the lamp quit rule generic (B18). It keeps `ConnectorRunning` and the `String`-keyed chain (decision 14). |
| **Phase 3 — TC002** (no plan in the tree yet) | `TileCandidate` reads `ulanziFace` to decide "not supported on TC002". | `ClockModel.ulanziTC002`, `UlanziFace` (optional, `nil` by default), the TC002 session with `{}` retraction per app name and restore on quit, `UlanziCustody`, and the one-clock health for either model. Each is in the re-verify table, and each Part B task names the Phase 3 symbol it touches. |
| **Lane C — Claude via the status line** | B17 stops using `ClaudeUsageConnector`'s `showsNow` closure: `live()` passes `{ true }`, because the tile's policy decides now. B20 deletes the closure and `Failure.outOfFocus` together with their tests, once lane C has landed. | `ClaudeUsageConnector.init(reporter:showsNow:)`, as Phase 2 D13 pins it. |
| **Phase 5 — UI** | It owes the switcher, rows, Add tile menu, tile detail and Clocks section. It calls `AppModel.availability(of:on:)`, `addTile`, `saveTile` and `removeTile` (B19), and `reloadClocks()` (B13). `MacFocus.displayName` is the checkbox text. Refresh slider labels, the eight-colour palette and `ColorPicker` are Phase 5's, because nothing here reads them. | — |

---

## Part A (4a) — the tile policy, pure

Every Part A type is a value with no I/O, so every task is plain red → green → mutate. Part A adds files and edits one existing file, `Sources/PixelClockTilesApp/FocusGate.swift`, in three hunks.

**What Part A reuses and what it leaves alone:**

- **Reused.** `IntervalScale.positions` and `IntervalScale.duration(atPosition:)` (A3). The existing `QuietWindow` and `DoNotDisturbDatabase.silencing` are *rewired onto* the new kit types (A1, A2), so the wrap-past-midnight arithmetic and the two silencing identifiers each have one home from Part A on.
- **Stays in the app, untouched.** `FocusAccess`, `ActiveFocusMode`, `FocusStatusReading`, `SystemFocusStatus` and `DoNotDisturbDatabase.activeMode`. They read macOS, and A11 resolves them into a `MacFocus` beside them.
- **Left for Part B.** `FocusGate`, `QuietRule` and `FocusRuleLine` (B16, B20), `ClaudeFocusAudience` and `FocusGatedConnector` (B17), and `VPNIndicatorPolicy` and `VPNLampDisplay` (B18). Each is still read by `AppModel`, and moving any of them now would break the app or duplicate it. `VPNIndicatorPolicy.workFocus` and `.personalFocus` repeat two of the four identifiers until B18 deletes them. That is the one duplication Part A leaves, because `VPNIndicatorPolicy.swift` sits next to the lamp custody Phase 2 is moving.

Existing signatures Part A builds on, verified in the tree:

```swift
// Sources/PixelClockKit/Scheduling/IntervalScale.swift
public enum IntervalScale {
    public static let positions: [TimeInterval]           // 5–60 min by 5, then 2–12 h; 23 steps
    public static func duration(atPosition position: Int) -> TimeInterval   // clamps
}
// Sources/PixelClockTilesApp/FocusGate.swift
enum FocusAccess: Equatable, Sendable { case notDetermined, denied, restricted, authorized }
enum ActiveFocusMode: Equatable, Sendable { case noFocus, mode(String), cannotTell }
protocol FocusStatusReading: Sendable { var access: FocusAccess { get }; var isFocused: Bool { get }; var activeMode: ActiveFocusMode { get }; func requestAccess() }
struct QuietWindow: Equatable, Sendable { var startHour: Int; var endHour: Int; func contains(_ moment: Date, in calendar: Calendar = .current) -> Bool; var label: String; static func clockFace(_ hour: Int) -> String }
enum DoNotDisturbDatabase { static let silencing: Set<String> }
// Tests/PixelClockTilesAppTests/Doubles.swift
final class StubFocusStatus: FocusStatusReading { init(access: FocusAccess = .notDetermined, isFocused: Bool = false, activeMode: ActiveFocusMode = .cannotTell); func nowIn(_ value: ActiveFocusMode) }
```

---

### Task A1: Name the Mac's Focus as six closed states

**Files:**
- Create: `Sources/PixelClockKit/Tiles/MacFocus.swift`
- Create: `Tests/PixelClockKitTests/MacFocusTests.swift`
- Modify: `Sources/PixelClockTilesApp/FocusGate.swift` (the import block, and `DoNotDisturbDatabase.silencing`)

**Interfaces:**
- Consumes: nothing
- Produces: `public enum MacFocus: String, CaseIterable, Codable, Hashable, Sendable` with cases `noFocus, work, personal, doNotDisturb, sleep, unknown`, plus `init(modeIdentifier:)`, `var modeIdentifier: String?` and `var displayName: String`

**Template:** `ActiveFocusMode` and `DoNotDisturbDatabase.silencing` in `FocusGate.swift`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/MacFocusTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// Six states and no more. The grid every tile policy is drawn over is these by
// twenty-four hours, so a seventh state would be a column nothing tests.

@Test func theStatesAreTheSixTheGridIsDrawnOver() {
    #expect(MacFocus.allCases == [.noFocus, .work, .personal, .doNotDisturb, .sleep, .unknown])
}

// Matched on the identifiers macOS ships and nobody can edit — never on the
// name, which reads "Работа" on the machine this was written on.
@Test func theFourBuiltInModesAreMatchedOnTheIdentifiersMacOSShips() {
    #expect(MacFocus(modeIdentifier: "com.apple.focus.work") == .work)
    #expect(MacFocus(modeIdentifier: "com.apple.focus.personal") == .personal)
    #expect(MacFocus(modeIdentifier: "com.apple.donotdisturb.mode.default") == .doNotDisturb)
    #expect(MacFocus(modeIdentifier: "com.apple.sleep.sleep-mode") == .sleep)
}

// Something is asserted, so it is not "nothing is on". Read as `.noFocus`, a
// Focus the user invented would run every tile that stays quiet in unnamed
// Focuses.
@Test func anIdentifierMacOSDidNotShipIsUnknownRatherThanNoFocus() {
    #expect(MacFocus(modeIdentifier: "com.apple.focus.fitness") == .unknown)
    #expect(MacFocus(modeIdentifier: "") == .unknown)
}

@Test func eachModeGivesBackTheIdentifierItIsMatchedOn() {
    let identified = MacFocus.allCases.filter { $0.modeIdentifier != nil }

    #expect(identified == [.work, .personal, .doNotDisturb, .sleep])
    for focus in identified {
        #expect(MacFocus(modeIdentifier: focus.modeIdentifier!) == focus)
    }
}

@Test func eachStateHasTheNameTheSettingsShow() {
    #expect(MacFocus.allCases.map(\.displayName) == [
        "No Focus", "Work", "Personal", "Do Not Disturb", "Sleep", "Other Focus",
    ])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MacFocusTests`
Expected: FAIL. The build stops at `cannot find 'MacFocus' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/MacFocus.swift
import Foundation

/// Which Focus the Mac is in, as a tile's policy reads it.
///
/// Closed on purpose: the four modes macOS ships, nothing on, and everything
/// else. A Focus the user invented is `.unknown` — its name is theirs to change
/// and its identifier is generated, so nothing about it can be matched.
///
/// Not `FocusState`, which is what the design called it: SwiftUI declares a
/// `FocusState` of its own, and every view file importing both would have to
/// qualify the name through a module whose namespace enum shadows it.
public enum MacFocus: String, CaseIterable, Codable, Hashable, Sendable {
    /// Spelled out rather than `none`, which reads as `Optional`'s own case at
    /// every site that holds one of these in an optional.
    case noFocus
    case work
    case personal
    case doNotDisturb
    case sleep
    case unknown

    /// The identifiers macOS ships for its four built-in modes.
    ///
    /// Matched on these and never on the mode's name beside them, which is
    /// localised and which the user can rename.
    static let builtIn: [String: MacFocus] = [
        "com.apple.focus.work": .work,
        "com.apple.focus.personal": .personal,
        "com.apple.donotdisturb.mode.default": .doNotDisturb,
        "com.apple.sleep.sleep-mode": .sleep,
    ]

    /// The mode an asserted identifier names, or `.unknown` for one macOS did
    /// not ship. Never `.noFocus`: something IS asserted, and reading it as
    /// nothing would run a tile through what might be Sleep.
    public init(modeIdentifier: String) {
        self = Self.builtIn[modeIdentifier] ?? .unknown
    }

    /// The identifier macOS asserts for this mode, or nil for the two states
    /// that are not a mode.
    public var modeIdentifier: String? {
        Self.builtIn.first { $0.value == self }?.key
    }

    /// What the settings and the refusal messages call it.
    public var displayName: String {
        switch self {
        case .noFocus: "No Focus"
        case .work: "Work"
        case .personal: "Personal"
        case .doNotDisturb: "Do Not Disturb"
        case .sleep: "Sleep"
        case .unknown: "Other Focus"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MacFocusTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Read the two silencing identifiers from `MacFocus`**

In `Sources/PixelClockTilesApp/FocusGate.swift`, add the kit to the imports:

```swift
import Foundation
import Intents
import PixelClockKit
```

Then replace the literal set inside `enum DoNotDisturbDatabase`. Keep the doc comment above it unchanged. Replace

```swift
    static let silencing: Set<String> = [
        "com.apple.donotdisturb.mode.default",
        "com.apple.sleep.sleep-mode",
    ]
```

with

```swift
    static let silencing: Set<String> = Set(
        [MacFocus.doNotDisturb, .sleep].compactMap(\.modeIdentifier)
    )
```

Run: `swift test --filter 'MacFocusTests|FocusModeTests|FocusGateTests'`
Expected: PASS. `FocusModeTests` (14) and `FocusGateTests` (36) are unchanged and green. The existing `doNotDisturbAndSleepSilenceTheSchedule` is now the production pin on these two identifiers.

- [ ] **Step 6: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `?? .unknown` → `?? .noFocus` in `init(modeIdentifier:)` | `anIdentifierMacOSDidNotShipIsUnknownRatherThanNoFocus` |
| swap the `.work` and `.personal` values in `builtIn` | `theFourBuiltInModesAreMatchedOnTheIdentifiersMacOSShips` |
| `[MacFocus.doNotDisturb, .sleep]` → `[MacFocus.doNotDisturb, .work]` in `silencing` | `FocusModeTests.doNotDisturbAndSleepSilenceTheSchedule` |

Restore after each and re-run `swift test --filter 'MacFocusTests|FocusModeTests'` green.

- [ ] **Step 7: Commit**

```bash
git add Sources/PixelClockKit/Tiles/MacFocus.swift Tests/PixelClockKitTests/MacFocusTests.swift Sources/PixelClockTilesApp/FocusGate.swift
git commit -m "feat: name the Mac's Focus as six closed states"
```

---

### Task A2: An hour window the kit owns, which the quiet window reads through

**Files:**
- Create: `Sources/PixelClockKit/Tiles/HourWindow.swift`
- Create: `Tests/PixelClockKitTests/HourWindowTests.swift`
- Modify: `Sources/PixelClockTilesApp/FocusGate.swift` (`QuietWindow.contains`, `label` and `clockFace`)

**Interfaces:**
- Consumes: nothing
- Produces: `public struct HourWindow: Hashable, Sendable` with `init(startHour:endHour:)` (hours read round the clock), `isEmpty`, `contains(hour:)`, `label` and `static func clockFace(_:)`

**Template:** `QuietWindow` (`FocusGate.swift`), without its direction and its `UserDefaults` keys.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/HourWindowTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Test func aWindowCoversTheHoursBetweenItsEnds() {
    let window = HourWindow(startHour: 9, endHour: 17)

    #expect(window.contains(hour: 8) == false)
    #expect(window.contains(hour: 9))
    #expect(window.contains(hour: 16))
    // Exclusive at the end, so 17:00 is the first hour outside again.
    #expect(window.contains(hour: 17) == false)
}

@Test func aWindowThatWrapsMidnightCoversBothSidesOfIt() {
    let night = HourWindow(startHour: 23, endHour: 8)

    #expect(night.contains(hour: 23))
    #expect(night.contains(hour: 0))
    #expect(night.contains(hour: 7))
    #expect(night.contains(hour: 8) == false)
    #expect(night.contains(hour: 22) == false)
}

@Test func aWindowOfZeroLengthCoversNothing() {
    let window = HourWindow(startHour: 3, endHour: 3)

    #expect(window.isEmpty)
    #expect((0..<24).allSatisfy { window.contains(hour: $0) == false })
}

// Every window the pickers can make, every hour: 576 windows, 13,824 answers,
// against a second statement of the rule that shares no code with the first —
// how far past the start the hour is, against how long the window is.
@Test func everyHourOfEveryWindowIsWhatItsTwoEndsSay() {
    for start in 0..<24 {
        for end in 0..<24 {
            let window = HourWindow(startHour: start, endHour: end)
            let length = (end - start + 24) % 24
            for hour in 0..<24 {
                let intoIt = (hour - start + 24) % 24
                #expect(
                    window.contains(hour: hour) == (intoIt < length),
                    "\(window.label) at \(hour):00"
                )
            }
        }
    }
}

@Test func hoursAreTakenRoundTheClock() {
    #expect(HourWindow(startHour: 24, endHour: 32) == HourWindow(startHour: 0, endHour: 8))
    #expect(HourWindow(startHour: -1, endHour: 8) == HourWindow(startHour: 23, endHour: 8))
    #expect(HourWindow(startHour: 23, endHour: 8).contains(hour: 24))
}

@Test func aWindowSaysItselfAsTwoHoursOnAClock() {
    #expect(HourWindow(startHour: 23, endHour: 8).label == "23:00–08:00")
    #expect(HourWindow(startHour: 0, endHour: 7).label == "00:00–07:00")
    #expect(HourWindow.clockFace(24) == "00:00")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HourWindowTests`
Expected: FAIL. `cannot find 'HourWindow' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/HourWindow.swift
import Foundation

/// A stretch of whole hours in the day, wrapping past midnight.
///
/// `QuietWindow` without its direction. Whether the hours inside are the quiet
/// ones or the working ones is the policy's to say (`TileWindow`); the window
/// only knows which hours it covers.
public struct HourWindow: Hashable, Sendable {
    /// The first hour inside, 0–23.
    public let startHour: Int
    /// The first hour outside again, 0–23 — so 23 to 8 covers 07:59 and not
    /// 08:00.
    public let endHour: Int

    /// Hours are taken round the clock, so a stored 24 is midnight rather than
    /// an hour no reading of the clock ever lands on.
    public init(startHour: Int, endHour: Int) {
        self.startHour = Self.roundTheClock(startHour)
        self.endHour = Self.roundTheClock(endHour)
    }

    /// Zero length is no window at all. The other reading — the whole day — is
    /// a tile gone permanently mute because a picker was scrolled one notch too
    /// far, with nothing on the panel to say why.
    public var isEmpty: Bool { startHour == endHour }

    public func contains(hour: Int) -> Bool {
        let hour = Self.roundTheClock(hour)
        guard !isEmpty else { return false }
        // 23 to 8 is the shipped quiet window, so the wrap is the case rather
        // than the edge case: two stretches with the day boundary between.
        guard startHour < endHour else { return hour >= startHour || hour < endHour }
        return hour >= startHour && hour < endHour
    }

    /// The window as the settings say it, `23:00–08:00`.
    public var label: String {
        "\(Self.clockFace(startHour))–\(Self.clockFace(endHour))"
    }

    /// An hour as a clock reads it. Written out rather than formatted, so the
    /// suite reads the same on every machine whatever its locale.
    public static func clockFace(_ hour: Int) -> String {
        String(format: "%02d:00", roundTheClock(hour))
    }

    private static func roundTheClock(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HourWindowTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Make `QuietWindow` read through it**

In `Sources/PixelClockTilesApp/FocusGate.swift` (the kit import is there since A1), keep `contains`'s doc comment ("Whether this moment falls inside the window…") and replace everything from `func contains(_ moment: Date, …` through the closing brace of `static func clockFace` with:

```swift
    func contains(_ moment: Date, in calendar: Calendar = .current) -> Bool {
        hours.contains(hour: calendar.component(.hour, from: moment))
    }

    /// The window as the settings say it, `23:00–08:00`.
    var label: String { hours.label }

    /// An hour as a clock reads it.
    static func clockFace(_ hour: Int) -> String {
        HourWindow.clockFace(hour)
    }

    /// The same two hours as the kit's window, which owns the arithmetic —
    /// the wrap past midnight and the zero-length rule — for this window and
    /// for every tile's.
    private var hours: HourWindow {
        HourWindow(startHour: startHour, endHour: endHour)
    }
```

The zero-length and wrap comments that were inside the old `contains` now live on `HourWindow.isEmpty` and `HourWindow.contains`. `stored(in:)`, `save(to:)`, the keys and `selectableHours` are unchanged.

Run: `swift test --filter 'HourWindowTests|FocusGateTests|PanelRenderingTests'`
Expected: PASS. `FocusGateTests`' five window tests now exercise `HourWindow` through `QuietWindow`.

- [ ] **Step 6: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| delete `guard !isEmpty else { return false }` | `aWindowOfZeroLengthCoversNothing`, `everyHourOfEveryWindowIsWhatItsTwoEndsSay`, **and** `FocusGateTests.aQuietWindowOfZeroLengthSilencesNothing` (run `--filter FocusGateTests` alone to prove the delegation carries it) |
| `hour >= startHour \|\| hour < endHour` → `&&` | `aWindowThatWrapsMidnightCoversBothSidesOfIt`, `FocusGateTests.aQuietWindowThatWrapsMidnightCoversBothSidesOfIt` |
| `self.startHour = Self.roundTheClock(startHour)` → `self.startHour = startHour` | `hoursAreTakenRoundTheClock` |

- [ ] **Step 7: Commit**

```bash
git add Sources/PixelClockKit/Tiles/HourWindow.swift Tests/PixelClockKitTests/HourWindowTests.swift Sources/PixelClockTilesApp/FocusGate.swift
git commit -m "feat: an hour window the kit owns, which the quiet window now reads through"
```

---

### Task A3: A refresh scale from thirty seconds, and the migration off the old index

**Files:**
- Create: `Sources/PixelClockKit/Tiles/RefreshScale.swift`
- Create: `Tests/PixelClockKitTests/RefreshScaleTests.swift`

**Interfaces:**
- Consumes: `IntervalScale.positions` and `IntervalScale.duration(atPosition:)`
- Produces: `public enum RefreshScale` with `steps: [TimeInterval]` (27 steps), `shortest`, `snapped(_:)` and `seconds(migratingIntervalPosition:) -> Int`

**Template:** `IntervalScale` (`Sources/PixelClockKit/Scheduling/IntervalScale.swift`). The new scale is the old one with four steps in front of it. It is not a copy.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/RefreshScaleTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Test func theScaleRunsFromHalfAMinuteToHalfADay() {
    #expect(RefreshScale.steps.count == 27)
    #expect(Array(RefreshScale.steps.prefix(5)) == [30, 60, 120, 180, 300])
    #expect(RefreshScale.steps[26] == 12 * 3600)
}

// The part above three minutes is the old scale, not a copy of it.
@Test func theStepsFromFiveMinutesUpAreTheIntervalScaleUnchanged() {
    #expect(Array(RefreshScale.steps.dropFirst(4)) == IntervalScale.positions)
}

@Test func theStepsOnlyEverGrow() {
    let steps = RefreshScale.steps
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
}

// Thirty seconds for every connector, whatever is stored.
@Test func nothingRunsMoreOftenThanEveryThirtySeconds() {
    for seconds: TimeInterval in [-60, 0, 1, 29, 30] {
        #expect(RefreshScale.snapped(seconds) == 30, "\(seconds) s")
    }
    #expect(RefreshScale.shortest == 30)
}

@Test func everyStepReadsBackAsItself() {
    for step in RefreshScale.steps {
        #expect(RefreshScale.snapped(step) == step)
    }
}

@Test func aValueBetweenStepsReadsAsTheNearestOne() {
    #expect(RefreshScale.snapped(44) == 30)
    #expect(RefreshScale.snapped(50) == 60)
    #expect(RefreshScale.snapped(250) == 300)
    #expect(RefreshScale.snapped(100_000) == 12 * 3600)
}

@Test func aValueExactlyBetweenTwoStepsTakesTheLongerOne() {
    #expect(RefreshScale.snapped(45) == 60)
    #expect(RefreshScale.snapped(240) == 300)
    #expect(RefreshScale.snapped(5_400) == 7_200)
}

// Index → duration → seconds. Reading the stored index against the new scale
// instead would turn every half-hourly anecdote into one every ten minutes.
@Test func aStoredIntervalPositionMigratesToTheDurationItMeant() {
    #expect(RefreshScale.seconds(migratingIntervalPosition: 0) == 300)
    #expect(RefreshScale.seconds(migratingIntervalPosition: 5) == 1_800)
    #expect(RefreshScale.seconds(migratingIntervalPosition: 22) == 43_200)
}

@Test func anOutOfRangePositionMigratesToTheEndItFellOff() {
    #expect(RefreshScale.seconds(migratingIntervalPosition: -3) == 300)
    #expect(RefreshScale.seconds(migratingIntervalPosition: 99) == 43_200)
}

@Test func everyMigratedIntervalIsAStepOfTheNewScale() {
    for position in IntervalScale.positions.indices {
        let seconds = TimeInterval(RefreshScale.seconds(migratingIntervalPosition: position))
        #expect(RefreshScale.snapped(seconds) == seconds, "position \(position)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RefreshScaleTests`
Expected: FAIL. `cannot find 'RefreshScale' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/RefreshScale.swift
import Foundation

/// How often a tile may run, from half a minute to half a day.
///
/// A refresh is stored in seconds and snapped to this scale when read, so a
/// value the scale cannot represent — a hand-edited one, a migrated one — is
/// read as the nearest step rather than honoured or refused.
public enum RefreshScale {
    /// 30 s, then 1, 2 and 3 min, in front of the interval scale the connectors
    /// have always had, which carries on behind them unchanged: 5–60 min in
    /// fives, then 2–12 h.
    public static let steps: [TimeInterval] = [30, 60, 120, 180] + IntervalScale.positions

    /// The shortest refresh any tile runs at, whatever is stored.
    public static var shortest: TimeInterval { steps[0] }

    /// The step nearest to `seconds`.
    ///
    /// Anything under the first step reads as the first step, which is the
    /// floor. A value exactly between two steps takes the LONGER one — walked
    /// from the top, the first of two equal distances is the higher step. The
    /// tie is only reached by a value nobody chose on a slider, and the longer
    /// step is the one that asks less of a clock and of a free public API.
    public static func snapped(_ seconds: TimeInterval) -> TimeInterval {
        steps.reversed().min { abs($0 - seconds) < abs($1 - seconds) } ?? shortest
    }

    /// What a stored `ConnectorSettings.intervalPosition` meant, in seconds.
    ///
    /// Through `IntervalScale`, never through `steps`: the position indexes the
    /// OLD scale, and four steps in front of it move every index — position 5
    /// is thirty minutes there and ten minutes here.
    public static func seconds(migratingIntervalPosition position: Int) -> Int {
        Int(IntervalScale.duration(atPosition: position))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'RefreshScaleTests|IntervalScaleTests'`
Expected: PASS. 10 new tests, and the 7 `IntervalScaleTests` untouched.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `[30, 60, 120, 180]` → `[60, 120, 180]` (the floor goes) | `nothingRunsMoreOftenThanEveryThirtySeconds`, `theScaleRunsFromHalfAMinuteToHalfADay` |
| `steps.reversed().min` → `steps.min` (ties go short) | `aValueExactlyBetweenTwoStepsTakesTheLongerOne` |
| `Int(IntervalScale.duration(atPosition: position))` → `Int(steps[min(max(position, 0), steps.count - 1)])` | `aStoredIntervalPositionMigratesToTheDurationItMeant` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/RefreshScale.swift Tests/PixelClockKitTests/RefreshScaleTests.swift
git commit -m "feat: a refresh scale from thirty seconds, and the migration off the old index"
```

---

### Task A4: A tile's Focus rule, with one home for the Focus it cannot name

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TilePolicy.swift`
- Create: `Tests/PixelClockKitTests/TilePolicyTests.swift`

**Interfaces:**
- Consumes: `MacFocus` (A1)
- Produces: `public struct FocusRule: Equatable, Sendable` with `silencedIn: Set<MacFocus>`, `whenUnknown: WhenUnknown` (`.run` | `.hold`) and `silences(_:)`

**Template:** `ClaudeFocusAudience.shows` (a switch over the mode, one answer per branch).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/TilePolicyTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// MARK: - The Focus rule

@Test func aTileIsQuietOnlyInTheFocusesItWasToldToBe() {
    let rule = FocusRule(silencedIn: [.doNotDisturb, .sleep])

    #expect(rule.silences(.doNotDisturb))
    #expect(rule.silences(.sleep))
    #expect(rule.silences(.noFocus) == false)
    #expect(rule.silences(.work) == false)
    #expect(rule.silences(.personal) == false)
}

@Test func aFocusThatCannotBeNamedFollowsWhenUnknown() {
    #expect(FocusRule(whenUnknown: .hold).silences(.unknown))
    #expect(FocusRule(whenUnknown: .run).silences(.unknown) == false)
}

// One home for the answer. The editor shows five boxes and a menu; a sixth,
// invisible box that overruled the menu would be state nobody can see or undo.
@Test func unknownInTheSetDoesNotOverruleWhenUnknown() {
    let rule = FocusRule(silencedIn: [.unknown], whenUnknown: .run)

    #expect(rule.silences(.unknown) == false)
}

@Test func whenUnknownSaysNothingAboutTheNamedStates() {
    let rule = FocusRule(silencedIn: [], whenUnknown: .hold)

    for focus in MacFocus.allCases where focus != .unknown {
        #expect(rule.silences(focus) == false, "\(focus)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TilePolicyTests`
Expected: FAIL. `cannot find 'FocusRule' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/TilePolicy.swift
import Foundation

/// Which Focuses a tile does not work in.
public struct FocusRule: Equatable, Sendable {
    /// What a tile does under a Focus the app cannot name.
    public enum WhenUnknown: String, Codable, Sendable {
        case run
        case hold
    }

    /// The named states the tile stays quiet in, edited as "works in" boxes.
    ///
    /// `.unknown` is not decided here even when it is in the set:
    /// `whenUnknown` decides it, so the answer has one home and a sixth box
    /// that nobody is shown cannot contradict the menu that is.
    public var silencedIn: Set<MacFocus>
    public var whenUnknown: WhenUnknown

    public init(silencedIn: Set<MacFocus> = [], whenUnknown: WhenUnknown = .run) {
        self.silencedIn = silencedIn
        self.whenUnknown = whenUnknown
    }

    public func silences(_ focus: MacFocus) -> Bool {
        switch focus {
        case .unknown:
            whenUnknown == .hold
        default:
            silencedIn.contains(focus)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TilePolicyTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `whenUnknown == .hold` → `whenUnknown == .run` | `aFocusThatCannotBeNamedFollowsWhenUnknown` |
| `silencedIn.contains(focus)` → `silencedIn.contains(focus) \|\| whenUnknown == .hold` | `whenUnknownSaysNothingAboutTheNamedStates` |
| `whenUnknown == .hold` → `silencedIn.contains(.unknown) \|\| whenUnknown == .hold` | `unknownInTheSetDoesNotOverruleWhenUnknown` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TilePolicy.swift Tests/PixelClockKitTests/TilePolicyTests.swift
git commit -m "feat: a tile's Focus rule, with one home for the Focus it cannot name"
```

---

### Task A5: A tile's hours: always, quiet or working

**Files:**
- Modify: `Sources/PixelClockKit/Tiles/TilePolicy.swift` (append)
- Modify: `Tests/PixelClockKitTests/TilePolicyTests.swift` (append)

**Interfaces:**
- Consumes: `HourWindow` (A2)
- Produces: `public enum TileWindow: Equatable, Sendable { case always, quiet(HourWindow), active(HourWindow) }` with `silences(atHour:)`

**Template:** `QuietWindow.contains`, now with a direction.

- [ ] **Step 1: Write the failing test.** Append to `TilePolicyTests.swift`:

```swift
// MARK: - The hours

@Test func aTileKeptAlwaysIsNeverSilencedByTheHour() {
    #expect((0..<24).allSatisfy { TileWindow.always.silences(atHour: $0) == false })
}

@Test func quietHoursSilenceInsideTheWindow() {
    let night = TileWindow.quiet(HourWindow(startHour: 23, endHour: 8))

    #expect(night.silences(atHour: 23))
    #expect(night.silences(atHour: 3))
    #expect(night.silences(atHour: 8) == false)
    #expect(night.silences(atHour: 12) == false)
}

@Test func workingHoursSilenceOutsideTheWindow() {
    let office = TileWindow.active(HourWindow(startHour: 10, endHour: 19))

    #expect(office.silences(atHour: 9))
    #expect(office.silences(atHour: 10) == false)
    #expect(office.silences(atHour: 18) == false)
    #expect(office.silences(atHour: 19))
}

// The same hours as quiet hours and as working hours are complements, for
// every window that covers anything and every hour of the day.
@Test func quietAndActiveOverTheSameHoursAreOpposites() {
    for start in 0..<24 {
        for end in 0..<24 where start != end {
            let window = HourWindow(startHour: start, endHour: end)
            for hour in 0..<24 {
                #expect(
                    TileWindow.quiet(window).silences(atHour: hour)
                        != TileWindow.active(window).silences(atHour: hour),
                    "\(window.label) at \(hour):00"
                )
            }
        }
    }
}

@Test func anEmptyWindowSilencesNothingEitherWay() {
    let nothing = HourWindow(startHour: 6, endHour: 6)

    #expect((0..<24).allSatisfy { TileWindow.quiet(nothing).silences(atHour: $0) == false })
    #expect((0..<24).allSatisfy { TileWindow.active(nothing).silences(atHour: $0) == false })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TilePolicyTests`
Expected: FAIL. `cannot find 'TileWindow' in scope`.

- [ ] **Step 3: Write minimal implementation.** Append to `TilePolicy.swift`:

```swift
/// The hours a tile keeps: all of them, all but a quiet stretch, or only a
/// working stretch.
public enum TileWindow: Equatable, Sendable {
    case always
    /// Silent inside the window.
    case quiet(HourWindow)
    /// Silent outside the window.
    case active(HourWindow)

    public func silences(atHour hour: Int) -> Bool {
        switch self {
        case .always:
            false
        case let .quiet(window):
            window.contains(hour: hour)
        case let .active(window):
            // An empty window restricts nothing in either direction. Read as
            // "no working hours", it would be a tile that never runs again
            // because a picker landed on the hour it started from.
            !window.isEmpty && !window.contains(hour: hour)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TilePolicyTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `!window.isEmpty && !window.contains(…)` → `!window.contains(…)` | `anEmptyWindowSilencesNothingEitherWay` |
| `!window.isEmpty && !window.contains(…)` → `!window.isEmpty && window.contains(…)` | `workingHoursSilenceOutsideTheWindow`, `quietAndActiveOverTheSameHoursAreOpposites` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TilePolicy.swift Tests/PixelClockKitTests/TilePolicyTests.swift
git commit -m "feat: a tile's hours — always, quiet, or working"
```

---

### Task A6: The tile policy, and why a tile is held — the hours before the Focus

**Files:**
- Modify: `Sources/PixelClockKit/Tiles/TilePolicy.swift` (append)
- Modify: `Tests/PixelClockKitTests/TilePolicyTests.swift` (append)

**Interfaces:**
- Consumes: `FocusRule` (A4), `TileWindow` (A5), `RefreshScale` (A3)
- Produces: `public enum TileHold { case paused, hours, focus }`, and `public struct TilePolicy: Equatable, Sendable` with `isPaused`, `refreshSeconds: Int`, `focus: FocusRule`, `window: TileWindow`, `refresh: TimeInterval`, `hold(in:atHour:) -> TileHold?` and `runs(in:atHour:)`

**Template:** `FocusGate.silence(quietHours:)`. Its order (window first, then Focus) is kept. The reason is load-bearing: the nightly refresh reads which hold it was.

The three guards are built **one per cycle, each new one in front of the last**, so the HANDOFF rule is exercised as it is written. After each guard is added, the mutations of the guards behind it are run again.

- [ ] **Step 1 (cycle 1, the Focus guard): Write the failing test.** Append to `TilePolicyTests.swift`:

```swift
// MARK: - The policy

private let sleepsAtNight = TilePolicy(
    refreshSeconds: 1_800,
    focus: FocusRule(silencedIn: [.sleep]),
    window: .quiet(HourWindow(startHour: 23, endHour: 8))
)

@Test func aTileHeldByItsFocusSaysSo() {
    #expect(sleepsAtNight.hold(in: .sleep, atHour: 12) == .focus)
    #expect(sleepsAtNight.hold(in: .work, atHour: 12) == nil)
    #expect(sleepsAtNight.runs(in: .work, atHour: 12))
}

@Test func theRefreshIsReadOnTheScale() {
    #expect(TilePolicy(refreshSeconds: 5).refresh == 30)
    #expect(TilePolicy(refreshSeconds: 1_800).refresh == 1_800)
    #expect(TilePolicy(refreshSeconds: 1_000).refresh == 900)
}

// Stored in seconds, snapped only when read: the stored value is what the user
// or the migration wrote, and nothing rewrites it behind their back.
@Test func theStoredRefreshIsKeptAsWritten() {
    #expect(TilePolicy(refreshSeconds: 1_000).refreshSeconds == 1_000)
}
```

Run: `swift test --filter TilePolicyTests`
Expected: FAIL. `cannot find 'TilePolicy' in scope`.

- [ ] **Step 2 (cycle 1): Write minimal implementation.** Append to `TilePolicy.swift`:

```swift
/// Why a tile is not running at a given moment.
public enum TileHold: Equatable, Sendable {
    /// Stopped by the user, with its settings kept.
    case paused
    /// Its hours say not now — inside quiet hours, or outside working ones.
    case hours
    /// The Mac is in a Focus the tile does not work in.
    case focus
}

/// What every tile carries about when it runs, whatever its connector.
///
/// Copied from the connector's defaults when the tile is created, then the
/// tile's own.
public struct TilePolicy: Equatable, Sendable {
    public var isPaused: Bool
    /// Seconds between runs as stored — for an event-driven tile, between
    /// rechecks. Read through `refresh`, which puts it on the scale.
    public var refreshSeconds: Int
    public var focus: FocusRule
    public var window: TileWindow

    public init(
        isPaused: Bool = false,
        refreshSeconds: Int,
        focus: FocusRule = FocusRule(),
        window: TileWindow = .always
    ) {
        self.isPaused = isPaused
        self.refreshSeconds = refreshSeconds
        self.focus = focus
        self.window = window
    }

    /// Seconds between runs, on the refresh scale and never under its floor.
    public var refresh: TimeInterval {
        RefreshScale.snapped(TimeInterval(refreshSeconds))
    }

    /// What holds the tile in this Focus at this hour, or nil when it runs.
    public func hold(in current: MacFocus, atHour hour: Int) -> TileHold? {
        if focus.silences(current) { return .focus }
        return nil
    }

    public func runs(in current: MacFocus, atHour hour: Int) -> Bool {
        hold(in: current, atHour: hour) == nil
    }
}
```

Run: `swift test --filter TilePolicyTests`
Expected: PASS, 12 tests.

Mutation G1: delete `if focus.silences(current) { return .focus }`. `aTileHeldByItsFocusSaysSo` must fail. Restore.

- [ ] **Step 3 (cycle 2, the hours guard in front): Write the failing test.** Append:

```swift
// The window is asked first, and the reason it names is load-bearing: the
// nightly refresh reads `.hours` to decide whether it may spend.
@Test func silentHoursAreTheReasonEvenWhenTheFocusAgrees() {
    #expect(sleepsAtNight.hold(in: .sleep, atHour: 3) == .hours)
    #expect(sleepsAtNight.hold(in: .work, atHour: 3) == .hours)
}
```

Run: `swift test --filter TilePolicyTests`
Expected: FAIL. `hold(in: .sleep, atHour: 3)` answers `.focus`, and `hold(in: .work, atHour: 3)` answers `nil`.

- [ ] **Step 4 (cycle 2): Implement.** Replace `hold(in:atHour:)` with:

```swift
    /// What holds the tile in this Focus at this hour, or nil when it runs.
    ///
    /// The hours come before the Focus because the answer is a reason as well
    /// as a verdict: the nightly refresh reads `.hours` to decide whether it
    /// may spend, and a 3 a.m. Sleep answered as `.focus` would let it load a
    /// model and spin the fans inside the hours somebody set aside for quiet.
    /// `FocusGate.silence` fixed that order, and it stays.
    public func hold(in current: MacFocus, atHour hour: Int) -> TileHold? {
        if window.silences(atHour: hour) { return .hours }
        if focus.silences(current) { return .focus }
        return nil
    }
```

Run: `swift test --filter TilePolicyTests`
Expected: PASS, 13 tests.

Mutations, one at a time:
- G2: delete the `window` line → `silentHoursAreTheReasonEvenWhenTheFocusAgrees` fails.
- Swap the two lines → `silentHoursAreTheReasonEvenWhenTheFocusAgrees` fails.
- **Re-run G1** (the guard this one now sits in front of) → `aTileHeldByItsFocusSaysSo` must still fail.

- [ ] **Step 5 (cycle 3, the pause guard in front of both): Write the failing test.** Append:

```swift
@Test func aPausedTileIsPausedWhateverTheHourAndTheFocus() {
    var paused = sleepsAtNight
    paused.isPaused = true

    for focus in MacFocus.allCases {
        for hour in 0..<24 {
            #expect(paused.hold(in: focus, atHour: hour) == .paused, "\(focus) at \(hour):00")
        }
    }
}
```

Run: `swift test --filter TilePolicyTests`
Expected: FAIL. 144 issues, because a paused tile answers `nil`, `.hours` or `.focus`.

- [ ] **Step 6 (cycle 3): Implement.** Replace `hold(in:atHour:)` with its final form:

```swift
    /// What holds the tile in this Focus at this hour, or nil when it runs.
    ///
    /// Paused first, then the hours, then the Focus. The hours come before the
    /// Focus because the answer is a reason as well as a verdict: the nightly
    /// refresh reads `.hours` to decide whether it may spend, and a 3 a.m.
    /// Sleep answered as `.focus` would let it load a model and spin the fans
    /// inside the hours somebody set aside for quiet. `FocusGate.silence`
    /// fixed that order, and it stays.
    public func hold(in current: MacFocus, atHour hour: Int) -> TileHold? {
        if isPaused { return .paused }
        if window.silences(atHour: hour) { return .hours }
        if focus.silences(current) { return .focus }
        return nil
    }
```

Run: `swift test --filter TilePolicyTests`
Expected: PASS, 14 tests.

Mutations, one at a time:
- G3: delete the `isPaused` line → `aPausedTileIsPausedWhateverTheHourAndTheFocus` fails.
- Move the `isPaused` line below the `window` line → the same test fails (hours 23–07 answer `.hours`).
- **Re-run G2 and G1**. Each must still fail its own test.

- [ ] **Step 7: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TilePolicy.swift Tests/PixelClockKitTests/TilePolicyTests.swift
git commit -m "feat: the tile policy and why a tile is held, the hours before the Focus"
```

---

### Task A7: The shapes of the policy's two new stored keys, pinned byte for byte

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TilePolicy+Coding.swift`
- Create: `Tests/PixelClockKitTests/TilePolicyCodingTests.swift`

**Interfaces:**
- Consumes: A4, A5
- Produces: `Codable` for `FocusRule` and `TileWindow`, in the shapes documented under [Persisted shapes](#persisted-shapes-reconciled-with-phase-1). `TilePolicy` itself is **not** `Codable`. The stored form is Phase 1's `TilePolicyRecord`, and B2 adds these two as its optional keys `focus` and `window`.

**Template:** `ConnectorSettings` (Codable, stored under `connector.<id>`). Written by hand here, because a synthesized `TileWindow` would store `{"quiet":{"_0":{…}}}` and a synthesized set would store its elements in launch-random order.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/TilePolicyCodingTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The two keys Part B adds to the stored policy are a contract with every
// launch that comes after this one, so they are pinned byte for byte rather
// than only round-tripped: a round trip passes just as happily after a renamed
// case has changed every stored value.

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

@Test func aFocusRuleIsWrittenInTheDocumentedShape() throws {
    let anecdotes = FocusRule(silencedIn: [.sleep, .doNotDisturb], whenUnknown: .hold)

    #expect(try json(anecdotes) == #"{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"}"#)
}

@Test func eachKindOfWindowIsWrittenByName() throws {
    #expect(try json(TileWindow.always) == #"{"kind":"always"}"#)
    #expect(
        try json(TileWindow.quiet(HourWindow(startHour: 23, endHour: 8)))
            == #"{"endHour":8,"kind":"quiet","startHour":23}"#
    )
    #expect(
        try json(TileWindow.active(HourWindow(startHour: 10, endHour: 19)))
            == #"{"endHour":19,"kind":"active","startHour":10}"#
    )
}

// Six elements, so a set written in its own order — which changes from launch
// to launch — matches the declared one by chance once in 720 runs, not once in
// two.
@Test func theQuietStatesAreWrittenInTheOrderTheyAreDeclared() throws {
    let everything = FocusRule(silencedIn: Set(MacFocus.allCases), whenUnknown: .run)

    #expect(try json(everything) == """
    {"silencedIn":["noFocus","work","personal","doNotDisturb","sleep","unknown"],\
    "whenUnknown":"run"}
    """)
}

@Test func everyRuleAndWindowSurvivesARoundTrip() throws {
    let rules = [
        FocusRule(),
        FocusRule(silencedIn: [.noFocus, .personal], whenUnknown: .hold),
    ]
    for rule in rules {
        #expect(try decoded(FocusRule.self, try json(rule)) == rule)
    }
    let windows: [TileWindow] = [
        .always,
        .quiet(HourWindow(startHour: 23, endHour: 8)),
        .active(HourWindow(startHour: 10, endHour: 19)),
    ]
    for window in windows {
        #expect(try decoded(TileWindow.self, try json(window)) == window)
    }
}

@Test func aStoredHourPastTheClockIsReadRoundIt() throws {
    let window = try decoded(TileWindow.self, #"{"kind":"quiet","startHour":24,"endHour":8}"#)

    #expect(window == .quiet(HourWindow(startHour: 0, endHour: 8)))
}

@Test func aWindowOfAKindThisAppDoesNotKnowIsRefused() {
    #expect(throws: DecodingError.self) {
        _ = try decoded(TileWindow.self, #"{"kind":"sometimes"}"#)
    }
}

@Test func aWindowMissingItsHoursIsRefused() {
    #expect(throws: DecodingError.self) {
        _ = try decoded(TileWindow.self, #"{"kind":"quiet","startHour":23}"#)
    }
}

@Test func aStateThisAppDoesNotKnowIsRefused() {
    #expect(throws: DecodingError.self) {
        _ = try decoded(FocusRule.self, #"{"silencedIn":["gaming"],"whenUnknown":"run"}"#)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TilePolicyCodingTests`
Expected: FAIL. `FocusRule` does not conform to `Encodable`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/TilePolicy+Coding.swift
import Foundation

// The shapes of a tile policy's two optional keys, `focus` and `window`, which
// Part B adds beside `isPaused` and `refreshSeconds` in the stored
// `TilePolicyRecord`. Written out by hand rather than synthesized, so a renamed
// case or a reordered set cannot change the bytes on disk:
//
//   "focus":{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"}
//   "window":{"endHour":8,"kind":"quiet","startHour":23}
//
// `window` is `{"kind":"always"}`, or `quiet` / `active` with both hours.

extension FocusRule: Codable {
    private enum Key: String, CodingKey {
        case silencedIn, whenUnknown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(
            silencedIn: Set(try container.decode([MacFocus].self, forKey: .silencedIn)),
            whenUnknown: try container.decode(WhenUnknown.self, forKey: .whenUnknown)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        // In declaration order rather than the set's own, which changes from
        // one launch to the next: the same policy is always the same bytes.
        try container.encode(MacFocus.allCases.filter(silencedIn.contains), forKey: .silencedIn)
        try container.encode(whenUnknown, forKey: .whenUnknown)
    }
}

extension TileWindow: Codable {
    private enum Key: String, CodingKey {
        case kind, startHour, endHour
    }

    private enum Kind: String, Codable {
        case always, quiet, active
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .always:
            self = .always
        case .quiet:
            self = .quiet(try Self.hours(in: container))
        case .active:
            self = .active(try Self.hours(in: container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .always:
            try container.encode(Kind.always, forKey: .kind)
        case let .quiet(window):
            try container.encode(Kind.quiet, forKey: .kind)
            try Self.write(window, into: &container)
        case let .active(window):
            try container.encode(Kind.active, forKey: .kind)
            try Self.write(window, into: &container)
        }
    }

    /// Through `HourWindow`'s initialiser, so a stored hour past the clock is
    /// read round it like any other.
    private static func hours(in container: KeyedDecodingContainer<Key>) throws -> HourWindow {
        HourWindow(
            startHour: try container.decode(Int.self, forKey: .startHour),
            endHour: try container.decode(Int.self, forKey: .endHour)
        )
    }

    private static func write(
        _ window: HourWindow, into container: inout KeyedEncodingContainer<Key>
    ) throws {
        try container.encode(window.startHour, forKey: .startHour)
        try container.encode(window.endHour, forKey: .endHour)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TilePolicyCodingTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `MacFocus.allCases.filter(silencedIn.contains)` → `Array(silencedIn)` | `theQuietStatesAreWrittenInTheOrderTheyAreDeclared` (1 run in 720 passes by chance, so run it twice) |
| `case always, quiet, active` → `case always, quiet = "silent", active` | `eachKindOfWindowIsWrittenByName` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TilePolicy+Coding.swift Tests/PixelClockKitTests/TilePolicyCodingTests.swift
git commit -m "feat: the stored shapes of a tile's Focus rule and hours"
```

---

### Task A8: The defaults a new tile starts from

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TileDefaults.swift`
- Create: `Tests/PixelClockKitTests/TileDefaultsTests.swift`

**Interfaces:**
- Consumes: `TilePolicy`
- Produces: `public enum TileDefaults` with `weather`, `claude`, `anecdotes` and `vpn`. These are the spec's defaults table. B3's `defaultPolicy` conformances read them, and so does B2's mapping, where a record Phase 1 wrote has no `focus` or `window` key.

**Template:** the spec table, row for row. `ClaudeFocusAudience` is the precedent for Claude's row: it hides only under Do Not Disturb and Sleep, and shows when the mode cannot be read.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/TileDefaultsTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The design's defaults table, row by row. Each row is spelled out in full
// rather than compared field by field, so a default gaining a field it should
// not have fails here too.

@Test func aNewWeatherTileRunsEveryTenMinutesThroughEverything() {
    #expect(TileDefaults.weather == TilePolicy(
        isPaused: false,
        refreshSeconds: 600,
        focus: FocusRule(silencedIn: [], whenUnknown: .run),
        window: .always
    ))
}

@Test func aNewClaudeTileRunsEveryFiveMinutesOutsideDoNotDisturbAndSleep() {
    #expect(TileDefaults.claude == TilePolicy(
        isPaused: false,
        refreshSeconds: 300,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .run),
        window: .always
    ))
}

@Test func aNewAnecdoteTileKeepsTheNightAndHoldsWhenItCannotTell() {
    #expect(TileDefaults.anecdotes == TilePolicy(
        isPaused: false,
        refreshSeconds: 1_800,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold),
        window: .quiet(HourWindow(startHour: 23, endHour: 8))
    ))
}

@Test func aNewVPNTileRechecksEveryMinuteThroughEverything() {
    #expect(TileDefaults.vpn == TilePolicy(
        isPaused: false,
        refreshSeconds: 60,
        focus: FocusRule(silencedIn: [], whenUnknown: .run),
        window: .always
    ))
}

// Every default is already on the scale, so no new tile starts at a refresh
// the slider cannot show.
@Test func everyDefaultRefreshIsAStepOfTheScale() {
    for policy in [TileDefaults.weather, TileDefaults.claude, TileDefaults.anecdotes, TileDefaults.vpn] {
        #expect(policy.refresh == TimeInterval(policy.refreshSeconds))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TileDefaultsTests`
Expected: FAIL. `cannot find 'TileDefaults' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/TileDefaults.swift
import Foundation

/// The policy each connector's new tile starts from — the design's defaults
/// table, one constant per row.
///
/// Values, not a registry: a tile copies one when it is created and owns the
/// copy from then on, so changing a row here moves new tiles and never an
/// existing one.
public enum TileDefaults {
    /// Ambient and silent, so nothing about a Focus or the hour applies.
    public static let weather = TilePolicy(refreshSeconds: 600)

    /// A lit figure is not what anybody wants under Do Not Disturb or beside a
    /// bed; an unnamed Focus keeps it, because hiding on "cannot tell" is an
    /// app that never appears on a machine without Full Disk Access.
    public static let claude = TilePolicy(
        refreshSeconds: 300,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .run)
    )

    /// The one tile that speaks, so the one that holds on "cannot tell" and
    /// keeps the night.
    public static let anecdotes = TilePolicy(
        refreshSeconds: 1_800,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold),
        window: .quiet(HourWindow(startHour: 23, endHour: 8))
    )

    /// Event-driven: the sixty seconds are the recheck between events.
    public static let vpn = TilePolicy(refreshSeconds: 60)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TileDefaultsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Mutate.** In `claude`, change `whenUnknown: .run` → `.hold`. `aNewClaudeTileRunsEveryFiveMinutesOutsideDoNotDisturbAndSleep` must fail. After A9 the grid picture fails too.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TileDefaults.swift Tests/PixelClockKitTests/TileDefaultsTests.swift
git commit -m "feat: the defaults a new tile starts from"
```

---

### Task A9: A policy as its 144-cell grid

**Files:**
- Create: `Sources/PixelClockKit/Tiles/PolicyGrid.swift`
- Create: `Tests/PixelClockKitTests/PolicyGridTests.swift`

**Interfaces:**
- Consumes: `TilePolicy.runs(in:atHour:)`, `MacFocus.allCases`
- Produces: `public struct PolicyGrid: Equatable, Sendable` with `Cell(focus:hour:)`, `running: Set<Cell>`, `init(_ policy:)`, internal `init(running:)`, `isEmpty` and `runs(in:atHour:)`; plus `TilePolicy.grid`

**Template:** none in the tree. This is the spec's "six states by 24 hours".

The tests draw each default as a picture of all 144 cells. One row per state, one column per hour. **Every cell of every default is pinned**, and a failing row reads as the hours it got wrong.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/PolicyGridTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// Each default drawn as a picture of all 144 cells: one row per state in the
// order `MacFocus` declares them, one column per hour from 00 to 23, `#` where
// the tile runs and `.` where it is held. Every cell is pinned, and a failing
// row reads as the hours it got wrong.

private func picture(_ grid: PolicyGrid) -> [String] {
    MacFocus.allCases.map { focus in
        String((0..<24).map { grid.runs(in: focus, atHour: $0) ? "#" : "." })
    }
}

private let allDay = String(repeating: "#", count: 24)
private let never = String(repeating: ".", count: 24)

@Test func theWeatherRunsInEveryCell() {
    #expect(picture(TileDefaults.weather.grid) == Array(repeating: allDay, count: 6))
}

@Test func theVPNRunsInEveryCell() {
    #expect(picture(TileDefaults.vpn.grid) == Array(repeating: allDay, count: 6))
}

@Test func claudeIsHeldAllDayUnderDoNotDisturbAndSleepAndNowhereElse() {
    #expect(picture(TileDefaults.claude.grid) == [
        allDay, // No Focus
        allDay, // Work
        allDay, // Personal
        never,  // Do Not Disturb
        never,  // Sleep
        allDay, // Other Focus — run
    ])
}

@Test func anecdotesKeepTheNightAndEveryFocusTheyCannotSpeakIn() {
    //                     000000000011111111112222
    //                     012345678901234567890123
    let daytime = "........###############."
    #expect(picture(TileDefaults.anecdotes.grid) == [
        daytime, // No Focus
        daytime, // Work
        daytime, // Personal
        never,   // Do Not Disturb
        never,   // Sleep
        never,   // Other Focus — hold
    ])
}

@Test func workingHoursInWorkOnlyLightTheOfficeDayOfOneRow() {
    let office = TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(
            silencedIn: [.noFocus, .personal, .doNotDisturb, .sleep], whenUnknown: .hold
        ),
        window: .active(HourWindow(startHour: 10, endHour: 19))
    )

    #expect(picture(office.grid) == [
        never,
        "..........#########.....", // Work, 10:00–19:00
        never, never, never, never,
    ])
}

@Test func aPausedTileRunsInNoCellAtAll() {
    var paused = TileDefaults.weather
    paused.isPaused = true

    #expect(paused.grid.isEmpty)
    #expect(picture(paused.grid) == Array(repeating: never, count: 6))
}

@Test func aGridHasOneCellPerStatePerHour() {
    #expect(TileDefaults.weather.grid.running.count == 144)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PolicyGridTests`
Expected: FAIL. `cannot find 'PolicyGrid' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/PolicyGrid.swift
import Foundation

/// Where a policy lets its tile run: every Focus state by every hour of the
/// day, 144 cells.
///
/// A policy is a function of those two values and nothing else, so its grid
/// is the whole of it. That is what makes two checks exact rather than
/// heuristic — two tiles claiming one lamp, and the tests, which enumerate it.
public struct PolicyGrid: Equatable, Sendable {
    public struct Cell: Hashable, Sendable {
        public let focus: MacFocus
        public let hour: Int

        public init(focus: MacFocus, hour: Int) {
            self.focus = focus
            self.hour = hour
        }
    }

    /// The cells the tile runs in.
    public let running: Set<Cell>

    public init(_ policy: TilePolicy) {
        var running = Set<Cell>()
        for focus in MacFocus.allCases {
            for hour in 0..<24 where policy.runs(in: focus, atHour: hour) {
                running.insert(Cell(focus: focus, hour: hour))
            }
        }
        self.running = running
    }

    init(running: Set<Cell>) {
        self.running = running
    }

    public var isEmpty: Bool { running.isEmpty }

    public func runs(in focus: MacFocus, atHour hour: Int) -> Bool {
        running.contains(Cell(focus: focus, hour: hour))
    }
}

extension TilePolicy {
    public var grid: PolicyGrid { PolicyGrid(self) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'PolicyGridTests|TileDefaultsTests'`
Expected: PASS. 7 new tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `for hour in 0..<24` → `0..<23` in `init(_:)` | every picture test, and `aGridHasOneCellPerStatePerHour` |
| A8's `claude` `whenUnknown: .run` → `.hold` | `claudeIsHeldAllDayUnderDoNotDisturbAndSleepAndNowhereElse` (row 6) |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/PolicyGrid.swift Tests/PixelClockKitTests/PolicyGridTests.swift
git commit -m "feat: a policy as its 144-cell grid"
```

---

### Task A10: The exact overlap of two grids, said as a person reads it

**Files:**
- Create: `Sources/PixelClockKit/Tiles/PolicyGrid+Overlap.swift`
- Create: `Tests/PixelClockKitTests/PolicyGridOverlapTests.swift`

**Interfaces:**
- Consumes: `PolicyGrid`, `HourWindow.label`, `MacFocus.displayName`
- Produces: `PolicyGrid.overlap(with:) -> PolicyGrid` and `PolicyGrid.summary: String`, e.g. `"Work, 10:00–19:00"`. B10's refusal message is built on these.

**Template:** `QuietWindow.label` / `FocusRuleLine`: sentences built in plain types so the suite can read them back.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/PolicyGridOverlapTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func workingIn(
    _ focuses: Set<MacFocus>, _ window: TileWindow = .always
) -> TilePolicy {
    TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(
            silencedIn: Set(MacFocus.allCases).subtracting(focuses).subtracting([.unknown]),
            whenUnknown: .hold
        ),
        window: window
    )
}

private func office(_ start: Int, _ end: Int) -> TileWindow {
    .active(HourWindow(startHour: start, endHour: end))
}

// The design's own example: one tunnel for the whole of Work, another for
// the office day inside it.
@Test func twoTilesOverlapExactlyWhereBothRun() {
    let pritunl = workingIn([.work]).grid
    let wireGuard = workingIn([.work], office(10, 19)).grid

    let overlap = pritunl.overlap(with: wireGuard)

    #expect(overlap.running.count == 9)
    #expect(overlap.summary == "Work, 10:00–19:00")
}

@Test func theOverlapIsTheSameWhicheverTileAsks() {
    let a = workingIn([.work, .personal]).grid
    let b = workingIn([.personal, .noFocus], office(8, 20)).grid

    #expect(a.overlap(with: b) == b.overlap(with: a))
}

@Test func tilesInDifferentFocusesShareALampWithoutOverlap() {
    let work = workingIn([.work]).grid
    let personal = workingIn([.personal]).grid

    #expect(work.overlap(with: personal).isEmpty)
}

// Working hours end where the next begin, exclusive, so a hand-over at 13:00
// is not a moment both tiles claim.
@Test func tilesAtAdjoiningHoursShareALampWithoutOverlap() {
    let morning = workingIn([.work], office(9, 13)).grid
    let afternoon = workingIn([.work], office(13, 18)).grid

    #expect(morning.overlap(with: afternoon).isEmpty)
}

@Test func aPausedTileOverlapsNothing() {
    var paused = workingIn([.work])
    paused.isPaused = true

    #expect(paused.grid.overlap(with: workingIn([.work]).grid).isEmpty)
}

// MARK: - Saying it

@Test func everyStateAllDayIsSaidAsAnyFocus() {
    #expect(TileDefaults.vpn.grid.summary == "any Focus, all day")
}

@Test func statesOverTheSameHoursAreNamedTogether() {
    let daytime = workingIn([.noFocus, .work, .personal], office(8, 23)).grid

    #expect(daytime.summary == "No Focus, Work and Personal, 08:00–23:00")
}

@Test func aStretchAcrossMidnightIsOneStretch() {
    let night = workingIn([.sleep], office(23, 8)).grid

    #expect(night.summary == "Sleep, 23:00–08:00")
}

// Quiet from ten to eight in Work leaves one stretch, from eight at night to
// ten in the morning — not two that happen to meet at midnight.
@Test func whatQuietHoursLeaveIsOneStretchRoundMidnight() {
    let evenings = workingIn([.work], .quiet(HourWindow(startHour: 10, endHour: 20))).grid

    #expect(evenings.summary == "Work, 20:00–10:00")
}

@Test func separateStretchesAreEachSaid() {
    let morning = workingIn([.work], office(8, 10)).grid
    let evening = workingIn([.work], office(20, 22)).grid

    #expect(PolicyGrid(running: morning.running.union(evening.running)).summary
        == "Work, 08:00–10:00 and 20:00–22:00")
}

@Test func differentHoursInDifferentStatesAreSaidApart() {
    let a = workingIn([.work], office(10, 19)).grid
    let b = workingIn([.personal]).grid

    #expect(PolicyGrid(running: a.running.union(b.running)).summary
        == "Work, 10:00–19:00; Personal, all day")
}

@Test func anEmptyGridSaysNothing() {
    #expect(workingIn([]).grid.summary == "")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PolicyGridOverlapTests`
Expected: FAIL. `value of type 'PolicyGrid' has no member 'overlap'`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Tiles/PolicyGrid+Overlap.swift
import Foundation

extension PolicyGrid {
    /// The cells both grids run in: where two tiles would both want the same
    /// lamp at the same moment. Exact — the grids are the whole of both
    /// policies.
    public func overlap(with other: PolicyGrid) -> PolicyGrid {
        PolicyGrid(running: running.intersection(other.running))
    }

    /// The cells as a person reads them — `Work, 10:00–19:00`.
    ///
    /// States that run over the same hours are named together, and all six at
    /// once as "any Focus"; a stretch across midnight is one stretch; the whole
    /// day is "all day". Empty for an empty grid.
    public var summary: String {
        var groups: [(focuses: [MacFocus], hours: Set<Int>)] = []
        for focus in MacFocus.allCases {
            let hours = Set((0..<24).filter { runs(in: focus, atHour: $0) })
            guard !hours.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.hours == hours }) {
                groups[index].focuses.append(focus)
            } else {
                groups.append((focuses: [focus], hours: hours))
            }
        }
        return groups
            .map { "\(Self.naming($0.focuses)), \(Self.stretches(of: $0.hours))" }
            .joined(separator: "; ")
    }

    private static func naming(_ focuses: [MacFocus]) -> String {
        guard focuses.count < MacFocus.allCases.count else { return "any Focus" }
        let names = focuses.map(\.displayName)
        guard let last = names.last, names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Each unbroken run of hours, walked round the clock so that 23:00 and
    /// 00:00 belong to the same stretch.
    private static func stretches(of hours: Set<Int>) -> String {
        guard hours.count < 24 else { return "all day" }
        let starts = hours.filter { !hours.contains(($0 + 23) % 24) }.sorted()
        return starts
            .map { start in
                var last = start
                while hours.contains((last + 1) % 24) { last = (last + 1) % 24 }
                return HourWindow(startHour: start, endHour: last + 1).label
            }
            .joined(separator: " and ")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PolicyGridOverlapTests`
Expected: PASS, 12 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `running.intersection(other.running)` → `running.union(other.running)` | `twoTilesOverlapExactlyWhereBothRun`, `tilesInDifferentFocusesShareALampWithoutOverlap` |
| `!hours.contains(($0 + 23) % 24)` → `!hours.contains($0 - 1)` (midnight splits a stretch) | `aStretchAcrossMidnightIsOneStretch`, `whatQuietHoursLeaveIsOneStretchRoundMidnight` |
| `where: { $0.hours == hours }` → `where: { $0.hours == hours && false }` (no grouping) | `statesOverTheSameHoursAreNamedTogether` |
| `focuses.count < MacFocus.allCases.count` → `<=` | `everyStateAllDayIsSaidAsAnyFocus` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/PolicyGrid+Overlap.swift Tests/PixelClockKitTests/PolicyGridOverlapTests.swift
git commit -m "feat: the exact overlap of two grids, said as a person reads it"
```

---

### Task A11: Resolve macOS's answer into the Focus tiles read

**Files:**
- Create: `Sources/PixelClockTilesApp/MacFocusResolution.swift`
- Create: `Tests/PixelClockTilesAppTests/MacFocusResolutionTests.swift`

**Interfaces:**
- Consumes: `FocusAccess`, `ActiveFocusMode`, `FocusStatusReading` (app); `MacFocus(modeIdentifier:)` (A1)
- Produces: `MacFocus.resolved(access:activeMode:isFocused:) -> MacFocus` and `MacFocus.init(reading:)`, both internal to the app target. B16 is the production caller.

**Template:** `FocusGate.rule(quietHours:)` + `activeFocusSilence`. It keeps their rules: the grant first, then the database, and the boolean only when the database cannot be read.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockTilesAppTests/MacFocusResolutionTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// How the Focus the Mac is in is read off macOS, keeping `FocusGate`'s rules:
// the grant first, then the database, and the boolean only when the database
// cannot be read.

private let everyMode: [ActiveFocusMode] = [
    .noFocus,
    .cannotTell,
    .mode("com.apple.focus.work"),
    .mode("com.apple.focus.personal"),
    .mode("com.apple.donotdisturb.mode.default"),
    .mode("com.apple.sleep.sleep-mode"),
    .mode("com.apple.focus.fitness"),
]

// Unauthorized, `isFocused` is false whatever is on — the answer an idle Mac
// gives — and a mode read without the grant is not evidence either. So nothing
// the centre says moves it off `.noFocus`, and every tile's hours decide alone.
@Test(arguments: [FocusAccess.notDetermined, .denied, .restricted])
func anUnauthorizedCentreIsNoFocusWhateverElseItSays(access: FocusAccess) {
    for mode in everyMode {
        for focused in [false, true] {
            #expect(
                MacFocus.resolved(access: access, activeMode: mode, isFocused: focused) == .noFocus,
                "\(mode), isFocused \(focused)"
            )
        }
    }
}

@Test func aModeReadFromTheDatabaseIsTheStateItNames() {
    let expected: [(String, MacFocus)] = [
        ("com.apple.focus.work", .work),
        ("com.apple.focus.personal", .personal),
        ("com.apple.donotdisturb.mode.default", .doNotDisturb),
        ("com.apple.sleep.sleep-mode", .sleep),
        ("com.apple.focus.fitness", .unknown),
    ]
    for (identifier, focus) in expected {
        for focused in [false, true] {
            #expect(
                MacFocus.resolved(
                    access: .authorized, activeMode: .mode(identifier), isFocused: focused
                ) == focus,
                "\(identifier), isFocused \(focused)"
            )
        }
    }
}

// The database is where the boolean's own answer comes from, so the two
// disagreeing is two reads a moment apart, not two opinions.
@Test func aDatabaseSayingNothingIsOnIsNoFocusWhateverTheBooleanSays() {
    #expect(MacFocus.resolved(access: .authorized, activeMode: .noFocus, isFocused: true) == .noFocus)
}

@Test func anUnreadableDatabaseLeavesTheBooleanToDecide() {
    #expect(
        MacFocus.resolved(access: .authorized, activeMode: .cannotTell, isFocused: false) == .noFocus
    )
    #expect(
        MacFocus.resolved(access: .authorized, activeMode: .cannotTell, isFocused: true) == .unknown
    )
}

@Test func theCentreIsReadThroughTheSameRule() {
    let status = StubFocusStatus(access: .authorized, isFocused: true, activeMode: .cannotTell)

    #expect(MacFocus(reading: status) == .unknown)

    status.nowIn(.mode("com.apple.sleep.sleep-mode"))
    #expect(MacFocus(reading: status) == .sleep)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MacFocusResolutionTests`
Expected: FAIL. `type 'MacFocus' has no member 'resolved'`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockTilesApp/MacFocusResolution.swift
import Foundation
import PixelClockKit

extension MacFocus {
    /// The Focus the Mac is in, as far as this app may believe macOS.
    ///
    /// | What macOS says                                   | MacFocus        |
    /// | ------------------------------------------------- | --------------- |
    /// | the centre is not authorized                      | `.noFocus`      |
    /// | authorized, a mode read from the database         | that mode, or `.unknown` |
    /// | authorized, the database says nothing is on       | `.noFocus`      |
    /// | authorized, no mode readable, `isFocused == false`| `.noFocus`      |
    /// | authorized, no mode readable, `isFocused == true` | `.unknown`      |
    ///
    /// An unauthorized centre is `.noFocus` rather than `.unknown` because its
    /// `isFocused` is false whatever is on, and a mode read without the grant
    /// is not evidence either — so every tile falls back to its hours alone,
    /// which is what `QuietRule.quietHours` did for the whole app.
    ///
    /// A mode read from the database wins over the boolean, which is the
    /// database's own summary read a moment apart.
    static func resolved(
        access: FocusAccess, activeMode: ActiveFocusMode, isFocused: Bool
    ) -> MacFocus {
        guard access == .authorized else { return .noFocus }
        switch activeMode {
        case let .mode(identifier):
            return MacFocus(modeIdentifier: identifier)
        case .noFocus:
            return .noFocus
        case .cannotTell:
            return isFocused ? .unknown : .noFocus
        }
    }

    /// The same rule, asked of the centre as it answers right now.
    init(reading status: any FocusStatusReading) {
        self = .resolved(
            access: status.access, activeMode: status.activeMode, isFocused: status.isFocused
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MacFocusResolutionTests`
Expected: PASS, 5 tests (one with 3 arguments).

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| delete `guard access == .authorized else { return .noFocus }` | `anUnauthorizedCentreIsNoFocusWhateverElseItSays` |
| `case .noFocus: return .noFocus` → `return isFocused ? .unknown : .noFocus` | `aDatabaseSayingNothingIsOnIsNoFocusWhateverTheBooleanSays` |
| `return isFocused ? .unknown : .noFocus` → `return .unknown` | `anUnreadableDatabaseLeavesTheBooleanToDecide` |

- [ ] **Step 6: Whole-suite gate for Part A**

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test`
Expected: PASS. The existing suite plus 72 new tests: 5 + 6 + 10 + 14 + 8 + 5 + 7 + 12 in the kit, and 5 in the app. Read a red wall-clock test against the machine's load, per HANDOFF § State, before calling it a defect.

- [ ] **Step 7: Commit**

```bash
git add Sources/PixelClockTilesApp/MacFocusResolution.swift Tests/PixelClockTilesAppTests/MacFocusResolutionTests.swift
git commit -m "feat: resolve macOS's Focus answer into the state tiles read"
```

---

## Part B (4b) — several clocks, one policy per tile

Part B runs **after Phases 1, 2 and 3 have landed**, on a tree where Part A has merged. It has two halves:

- **B1–B12, the kit.** Pure types and `UserDefaults` steps. B3 edits the shipped connectors, and B7 also moves the weather place's reader and writer in the app, because a migration step lands with its reader. The kit code of B1, B2 and B4–B12, and all five migration steps with their tests, were compiled and run in a scratch package against Phase 1's declarations, copied from its plan, and against a stand-in for Phase 2's `Connector` and `AwtrixFace`. Every mutation in those tables was run and died. B3's connector edits and B7's `LocationField` and `AppModel` edits touch files Phases 1–3 are still writing, and their own steps verify them.
- **B13–B19, the wiring.** These edit `AppModel`, 42% of whose commits were fixes, and `live()`. They are written against the Phase 1 and Phase 2 plans' declared shapes. Phase 3 has no plan in the tree yet, so each Phase 3 symbol a task touches is named in that task and in the table below. The wiring tasks are sized one concern each, because a defect found in a 3-file commit costs one round of review and a defect found in a 24-file commit costs five.

Each migration step lands **in the same commit as the reader that stops the app writing its source key** (Phase 1 D3, spec § Persistence). Where a step and its reader are two tasks, the first ends with its files staged and green, and the second commits both.

## Re-verify before executing

Before B1, look up every symbol below: `mcp__tea-rags__find_symbol` with `path="/Users/artk0re/Dev/Personal/awtrix-connectors"`, or `rg` if the index is still drifting. Where a signature differs from the one assumed here, adapt the task that uses it, and name the adaptation in that task's commit message. Where a symbol is missing altogether, stop and ask the parent. Do not invent it.

| Symbol | Declared by | Assumed signature | Used in |
| --- | --- | --- | --- |
| `ClockModel` | Phase 1 T1 | `public enum ClockModel: String, Codable, Sendable { case awtrix3, ulanziTC002 }` | B11, B13, B15, B18 |
| `ClockRecord` | Phase 1 T1 | `public struct ClockRecord: Codable, Sendable, Equatable { let id: UUID; var name: String; var model: ClockModel; var address: String; var hardwareIdentity: String? }`, `init(id: UUID = UUID(), name:model:address:hardwareIdentity: String? = nil)` | B11, B13, B14 |
| `ClockStore` | Phase 1 T1 | `static let key = "clocks"`, `init(defaults:)`, `all()`, `replaceAll(_:) throws`, `update(_:_:)`, `firstClock(orCreatingAt:)` | B13, B15, B18 |
| `TileKey` | Phase 1 T4 | `Codable, Sendable, Hashable`; `clockId`, `connectorId`, `instance`; `init(clockId:connectorId:instance: = "")` | all |
| `TilePolicyRecord` | Phase 1 T4 | `Codable, Sendable, Equatable`; `var isPaused: Bool`, `var refreshSeconds: Int`; `init(isPaused:refreshSeconds:)` | B2 |
| `TileRecord` | Phase 1 T4 | `let key: TileKey`, `var policy: TilePolicyRecord`, `var lastDeliveredAt: Date?`; `init(key:policy:lastDeliveredAt: = nil)` | B6 and on |
| `TileStore` | Phase 1 T4 | `static let key = "tiles"`, `init(defaults:)`, `all()`, `replaceAll(_:) throws`, `update(_:_:)` (inserts when absent) | B7, B13, B16, B18, B19 |
| `TileSettingsStore` | Phase 1 T5 | `public final class TileSettingsStore: SettingsStore`, `init(defaults:clockId:)` | B13 |
| `ClockMigration`, `TileMigration` | Phase 1 T2, T6 | `static let markerKey` (`migration.clocks`, `migration.tiles`), `run() throws`; run in `live()` in that order | B7, B14–B16, B18 |
| `RecordingDefaults` (tests) | Phase 1 T2 | `final class RecordingDefaults: UserDefaults`, `writes: [String]` | B7, B14–B16, B18 |
| `AppModel.init(clock: ClockRecord, …)`, `private var clock`, `private let clocks: ClockStore`; `testModel(…, deviceHost:, hardwareIdentity:)` | Phase 1 T3 | as named | B13 |
| `ConnectorRunning` (app) | Phase 2 T2/T3 | `maintain(connectorId:)`, `runOnce(connectorId:)`, `deliver(_: AwtrixDelivery)`, `nextDelay(connectorId:interval:)`, `restoreDeviceState(borrowedBy:)` | B13, B15, B17 |
| `AwtrixClockSession` | Phase 2 T2/T5 | `init(device:registry:store:audio:iconInstaller:retryPolicy:borrowedOverlays:)`; `public nonisolated let indicators: IndicatorCustody` | B13, B15, B18 |
| `IndicatorCustody`, `IndicatorLighting` | Phase 2 T5 | `public actor IndicatorCustody { init(lamps:); func show(_ signal: IndicatorSignal, on slot: IndicatorSlot) async }` | B18 |
| `Connector`, `AwtrixFace`, `AwtrixDelivery`, `produce()` | Phase 2 T3/T4 | `protocol Connector { associatedtype Reading; var id; var isAudible; var defaultInterval; func read() async throws -> Reading; var awtrixFace: AwtrixFace<Reading> { get } }`; `AwtrixFace.init(_ render: @Sendable (Reading) -> AwtrixDelivery)`; `AwtrixDelivery(text:)` with every other field defaulted | B3, B11 |
| `VPNLampDisplay(indicators:)`, `VPNLamps` | Phase 2 T5 | app | B18 (deleted) |
| health in `AppModel` | Phase 2 D9 | `monitor: DeviceMonitor`, `poll()`, `followTheClock()`, `unansweredPolls`, `alerts: any BatteryWarningPresenting` | B14 |
| `UlanziFace<Reading>`, `Connector.ulanziFace` | **Phase 3b** | `var ulanziFace: UlanziFace<Reading>? { get }`, `nil` by default in a protocol extension | B11 |
| the TC002 session | **Phase 3** | an actor conforming to `ConnectorRunning` whose `restoreDeviceState(borrowedBy: id)` sends `{}` for that connector's app, and `(nil)` for every app it owns | B13, B17 |
| how `live()` picks a session by `ClockModel` | **Phase 3** | one branch on `clock.model` building the session, its device and its health | B13, B14 |
| TC002 health | **Phase 3** | reachable while `/getBase` answers, and no battery | B14 |
| `ClaudeUsageConnector.init(reporter:showsNow:)`, `Failure.outOfFocus` | Lane C / Phase 2 D13 | as named | B17, B20 |

Symbols that exist in the tree today and that Part B reads, with their real signatures:

```swift
// Sources/PixelClockKit/Weather/OpenMeteoSource.swift
public struct Coordinates: Sendable, Equatable, Codable { public let latitude: Double; public let longitude: Double }
public actor OpenMeteoSource { public init(transport: any Transport, now: @escaping @Sendable () -> Date = Date.init); public func reading(at place: Coordinates) async throws -> WeatherReading }
// Sources/PixelClockKit/Connectors/WeatherConnector.swift
public init(source: OpenMeteoSource, location: @escaping @Sendable () -> Coordinates)
// Sources/PixelClockTilesApp/LocationField.swift
extension Coordinates { public static let `default`; static let storageKey = "weatherLocation"; static func stored(in:) -> Coordinates; func save(to:) }
final class StoredLocation: @unchecked Sendable { init(defaults:); var current: Coordinates }
enum LocationField { @discardableResult static func save(_ typed: String, to defaults: UserDefaults) -> String }
// Sources/PixelClockKit/Device/DeviceIndicator.swift
public enum IndicatorSlot: Int, Sendable, CaseIterable { case topRight = 1, middleRight = 2, bottomRight = 3 }
public enum IndicatorSignal: Equatable, Sendable { case off, steady(String), blinking(String, everyMilliseconds: Int) }
// Sources/PixelClockTilesApp/VPNPresence.swift
struct WatchedVPN: Sendable, Equatable { let bundle: String; let tunnelBinaries: Set<String>; static let pritunl; static let amnezia }
struct VPNPresence: Sendable { init(processes: any RunningProcessListing = SystemProcessList()); func isUp(_ vpn: WatchedVPN) -> Bool }
// Sources/PixelClockKit/Device/BorrowedOverlayStore.swift, BatteryHistoryStore.swift
public final class UserDefaultsBorrowedOverlayStore: BorrowedOverlayStore { private static let key = "borrowedOverlay"; public init(defaults: UserDefaults = .standard) }
public final class UserDefaultsBatteryHistoryStore: BatteryHistoryStore { private static let key = "batteryHistory"; public init(defaults: UserDefaults = .standard) }
public struct BatteryHistory: Sendable, Codable, Equatable { public let uid: String; public let uptime: Int?; public let samples: [BatterySample] }
// Sources/PixelClockKit/Device/DeviceMonitor.swift
@MainActor public final class DeviceMonitor: ObservableObject { public init(device: AwtrixDevice, history: any BatteryHistoryStore = InMemoryBatteryHistoryStore()); @discardableResult public func refresh(at now: Date = Date()) async -> BatteryWarning?; public var isOnline: Bool }
// Sources/PixelClockTilesApp/BatteryAlert.swift
protocol BatteryWarningPresenting: Sendable { @MainActor func warn(_ warning: BatteryWarning) async }
enum BatteryAlertWords { static func title(for warning: BatteryWarning) -> String; static func body(for warning: BatteryWarning) -> String }
// Sources/PixelClockTilesApp/AppModel.swift (as of 39d7072; Phases 1–3 rename around them)
func reactToAFocusChange(); func refreshVPNIndicators(); private func scheduleHold(for connectorId: String) -> String?
private var duringTheQuietWindow: Bool; private func reschedule(_ connector: any Connector, resuming: Bool = false)
private func tick(_ id: String) async; func teardown() async; func setQuietHours(_ window: QuietWindow); var focusRule: QuietRule
// Sources/PixelClockTilesApp/SystemChangeWatcher.swift
final class NetworkPathWatcher { func start(_ changed: @escaping @Sendable () -> Void); func stop() }
final class FocusAssertionsWatcher { func start(…); func stop() }
// Tests/PixelClockTilesAppTests/Doubles.swift
final class SpyHost: ConnectorRunning  // calls: "maintain:<id>", "run:<id>", "deliver:<text>", "restore:<id>|restore:all"
final class Gate { func open(); func enter() async; var enteredCount: Int }
final class Metronome { var sleep; func tick(); var parked: Int; var durations: [TimeInterval] }
func waitUntil(_ condition: @MainActor () -> Bool, limit: TimeInterval? = nil) async -> Bool
let parked: @Sendable (TimeInterval) async throws -> Void
```

---

### Task B1: Weather cached per place, so two tiles do not evict each other

**Files:**
- Modify: `Sources/PixelClockKit/Weather/OpenMeteoSource.swift` (`Coordinates` conformance; `cached`; `reading(at:)`)
- Modify: `Tests/PixelClockKitTests/OpenMeteoSourceTests.swift` (append)

**Interfaces:**
- Consumes: nothing new
- Produces: `Coordinates: Hashable`; `OpenMeteoSource.reading(at:)` keeps one answer per place. The production caller is unchanged: the weather connector, one per clock from B13.

**Template:** `OpenMeteoSource` itself. The write-on-success rule and the interval-from-the-response rule are kept byte for byte.

- [ ] **Step 1: Write the failing tests.** Append to `OpenMeteoSourceTests.swift`, which already has `moscow`, `berlin`, `body(…)` and the private `Clock`:

```swift
// MARK: - One answer per place

// Two weather tiles at two places, polled in turn. Held in one slot, each poll
// evicted the other place's answer and every run went to the network.
@Test func twoPlacesPolledInTurnAreEachAnsweredFromTheirOwnCache() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(code: 71)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    transport.body = body(code: 0)
    _ = try await source.reading(at: berlin)
    clock.advance(60)
    let moscowAgain = try await source.reading(at: moscow)
    let berlinAgain = try await source.reading(at: berlin)

    #expect(transport.requests.count == 2)
    #expect(moscowAgain.code == 71)
    #expect(berlinAgain.code == 0)
}

@Test func eachPlaceAgesOnItsOwnInterval() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body()
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    clock.advance(500)
    _ = try await source.reading(at: berlin)
    clock.advance(401)
    _ = try await source.reading(at: moscow)
    _ = try await source.reading(at: berlin)

    // Moscow's 900 seconds are up and Berlin's are not.
    #expect(transport.requests.count == 3)
    #expect(transport.requests.last?.url?.absoluteString.contains("latitude=55.7558") == true)
}

@Test func aFailedFetchForOnePlaceLeavesAnotherPlacesAnswerStanding() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(code: 71)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    transport.status = 500
    _ = try? await source.reading(at: berlin)
    let moscowAgain = try await source.reading(at: moscow)

    #expect(transport.requests.count == 2)
    #expect(moscowAgain.code == 71)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter OpenMeteoSourceTests`
Expected: FAIL. `twoPlacesPolledInTurnAreEachAnsweredFromTheirOwnCache` sees 4 requests, and `eachPlaceAgesOnItsOwnInterval` sees 4. `aFailedFetchForOnePlaceLeavesAnotherPlacesAnswerStanding` passes already: it pins that the keyed cache keeps the write-on-success rule, and it has to stay green through Step 3.

- [ ] **Step 3: Implement.** In `OpenMeteoSource.swift`, change `public struct Coordinates: Sendable, Equatable, Codable {` to `public struct Coordinates: Sendable, Hashable, Codable {`. Replace the `cached` property and its doc comment with:

```swift
    /// The last answer for each place, and when it was given.
    ///
    /// Keyed by the place rather than holding one answer. One slot served the
    /// app while there was one location; two weather tiles at two places would
    /// evict each other on every poll, and each would fetch on every run
    /// however fresh the other's answer was.
    private var cached: [Coordinates: (reading: WeatherReading, at: Date)] = [:]
```

and the body of `reading(at:)` with:

```swift
        if let hit = cached[place], now().timeIntervalSince(hit.at) < hit.reading.interval {
            return hit.reading
        }

        let reading = try await fetch(place)
        // Written only on success, so one outage is not served as the weather
        // for the whole of the next interval.
        cached[place] = (reading, now())
        return reading
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter OpenMeteoSourceTests`
Expected: PASS, 12 tests (the 9 that were there and the 3 above). `movingTheLocationRefetchesRatherThanAnsweringAboutTheOldPlace` still passes, now for a different reason: the new place has no entry.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `cached[place] = (reading, now())` → `cached = [place: (reading, now())]` (back to one slot) | `twoPlacesPolledInTurnAreEachAnsweredFromTheirOwnCache` |
| `if let hit = cached[place],` → `if let hit = cached.values.first,` | `movingTheLocationRefetchesRatherThanAnsweringAboutTheOldPlace` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Weather/OpenMeteoSource.swift Tests/PixelClockKitTests/OpenMeteoSourceTests.swift
git commit -m "feat: weather cached per place, so two tiles do not evict each other"
```

---

### Task B2: The stored policy gains the Focus and the hours

**Files:**
- Modify: `Sources/PixelClockKit/Tiles/TileRecord.swift` (Phase 1's `TilePolicyRecord`)
- Create: `Sources/PixelClockKit/Tiles/TilePolicyRecord+Policy.swift`
- Create: `Tests/PixelClockKitTests/TilePolicyRecordTests.swift`

**Interfaces:**
- Consumes: `TilePolicyRecord` (Phase 1), `TilePolicy`, `FocusRule`, `TileWindow` and their coding (A6, A7), `TileDefaults` (A8)
- Produces: `TilePolicyRecord.focus: FocusRule?` and `.window: TileWindow?`, whose `init` gains `focus: FocusRule? = nil, window: TileWindow? = nil`; `TilePolicy.init(_ record: TilePolicyRecord, defaults: TilePolicy)`; `TilePolicyRecord.init(_ policy: TilePolicy)`. Production callers: the migration steps (B16, B18), the schedule (B16) and saving a tile (B19).

**The mapping, stated once.** Stored → evaluated: `isPaused` and `refreshSeconds` are copied, and `focus` and `window` are taken from the record when present, otherwise from the connector's `defaultPolicy` (B3), which is its `TileDefaults` row. Evaluated → stored: all four are written, so from Phase 4 on a saved record never leans on a default that may change later. Every record Phase 1 wrote lacks both keys and reads as its row. That is what each connector did with Focuses and hours before tiles, apart from the anecdotes' quiet hours, which B16's migration step writes explicitly. The migrated VPN tiles are written with their `focus` (B18), so their `whenUnknown: hold` never falls back to the VPN row's `run`.

**Template:** `ConnectorSettings.lastDeliveredAt`. It is an optional field that decodes as absent from a key written before it existed, and it is the rule Phase 1 names for extending `TilePolicyRecord`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/TilePolicyRecordTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func record(_ text: String) throws -> TilePolicyRecord {
    try JSONDecoder().decode(TilePolicyRecord.self, from: Data(text.utf8))
}

// What Phase 1 wrote. Its Focus rule and hours are whatever every tile of its
// connector had until now, which is the defaults row.
@Test func aRecordFromBeforeTheFocusAndTheHoursReadsThemFromTheDefaults() throws {
    let stored = try record(#"{"isPaused":true,"refreshSeconds":1800}"#)

    let policy = TilePolicy(stored, defaults: TileDefaults.anecdotes)

    #expect(policy == TilePolicy(
        isPaused: true,
        refreshSeconds: 1_800,
        focus: TileDefaults.anecdotes.focus,
        window: TileDefaults.anecdotes.window
    ))
}

@Test func whatARecordSaysWinsOverTheDefaults() throws {
    let stored = try record("""
    {"focus":{"silencedIn":[],"whenUnknown":"run"},"isPaused":false,"refreshSeconds":300,\
    "window":{"kind":"always"}}
    """)

    let policy = TilePolicy(stored, defaults: TileDefaults.anecdotes)

    #expect(policy.focus == FocusRule(silencedIn: [], whenUnknown: .run))
    #expect(policy.window == .always)
}

@Test func onlyTheMissingKeyIsTakenFromTheDefaults() throws {
    let stored = try record(#"{"isPaused":false,"refreshSeconds":300,"window":{"kind":"always"}}"#)

    let policy = TilePolicy(stored, defaults: TileDefaults.anecdotes)

    #expect(policy.focus == TileDefaults.anecdotes.focus)
    #expect(policy.window == .always)
}

// Written out whole, so a defaults row changed later never moves a tile the
// user already has.
@Test func aPolicyIsStoredWithEveryKeyWrittenOut() throws {
    #expect(try json(TilePolicyRecord(TileDefaults.anecdotes)) == """
    {"focus":{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"},\
    "isPaused":false,"refreshSeconds":1800,\
    "window":{"endHour":8,"kind":"quiet","startHour":23}}
    """)
}

@Test func aRecordWithoutTheNewKeysIsStillWrittenInPhaseOnesShape() throws {
    #expect(try json(TilePolicyRecord(isPaused: false, refreshSeconds: 600))
        == #"{"isPaused":false,"refreshSeconds":600}"#)
}

@Test func aPolicySurvivesTheRoundTripThroughItsRecord() throws {
    let policy = TilePolicy(
        isPaused: true,
        refreshSeconds: 45,
        focus: FocusRule(silencedIn: [.work], whenUnknown: .hold),
        window: .active(HourWindow(startHour: 10, endHour: 19))
    )
    let stored = try record(try json(TilePolicyRecord(policy)))

    // The weather row is the wrong defaults on purpose: nothing may come from it.
    #expect(TilePolicy(stored, defaults: TileDefaults.weather) == policy)
    // Kept as stored and snapped only when read.
    #expect(stored.refreshSeconds == 45)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TilePolicyRecordTests`
Expected: FAIL. `extra argument 'focus' in call` / `type 'TilePolicy' has no member 'init(_:defaults:)'`.

- [ ] **Step 3: Implement.** In `Sources/PixelClockKit/Tiles/TileRecord.swift`, give `TilePolicyRecord` its two optional fields. Phase 1's two fields and their comments are unchanged:

```swift
    /// The Focuses the tile does not work in, or nil for a record written
    /// before Phase 4 — read as the connector's own defaults row.
    public var focus: FocusRule?
    /// The hours the tile keeps, or nil for a record written before Phase 4.
    public var window: TileWindow?

    public init(
        isPaused: Bool, refreshSeconds: Int, focus: FocusRule? = nil, window: TileWindow? = nil
    ) {
        self.isPaused = isPaused
        self.refreshSeconds = refreshSeconds
        self.focus = focus
        self.window = window
    }
```

The synthesized `Codable` decodes an absent key as nil and omits a nil one, so Phase 1's pinned shape still round-trips. Then create:

```swift
// Sources/PixelClockKit/Tiles/TilePolicyRecord+Policy.swift
import Foundation

extension TilePolicy {
    /// What a stored record means, with anything it does not say taken from
    /// the connector's defaults row.
    ///
    /// A record written before Phase 4 carries only `isPaused` and
    /// `refreshSeconds`. Its Focus rule and hours are the ones every tile of
    /// its connector had until then, which is what the defaults row says, so
    /// reading the absent keys as the row changes nothing the user chose.
    public init(_ record: TilePolicyRecord, defaults: TilePolicy) {
        self.init(
            isPaused: record.isPaused,
            refreshSeconds: record.refreshSeconds,
            focus: record.focus ?? defaults.focus,
            window: record.window ?? defaults.window
        )
    }
}

extension TilePolicyRecord {
    /// Everything the policy says, written out. From Phase 4 on a saved record
    /// never leans on a default, so a defaults row changed later moves new
    /// tiles and never one the user already has.
    public init(_ policy: TilePolicy) {
        self.init(
            isPaused: policy.isPaused,
            refreshSeconds: policy.refreshSeconds,
            focus: policy.focus,
            window: policy.window
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter 'TilePolicyRecordTests|TileStoreTests|TileSettingsStoreTests|TileMigrationTests'`
Expected: PASS. 6 new tests, and Phase 1's record, store and migration tests unchanged.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `focus: record.focus ?? defaults.focus` → `focus: defaults.focus` | `whatARecordSaysWinsOverTheDefaults` |
| `window: record.window ?? defaults.window` → `window: record.window ?? .always` | `aRecordFromBeforeTheFocusAndTheHoursReadsThemFromTheDefaults` |
| `window: policy.window` → `window: nil` in `TilePolicyRecord.init(_:)` | `aPolicyIsStoredWithEveryKeyWrittenOut` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TileRecord.swift Sources/PixelClockKit/Tiles/TilePolicyRecord+Policy.swift Tests/PixelClockKitTests/TilePolicyRecordTests.swift
git commit -m "feat: a tile's stored policy gains the Focus and the hours, defaulting to its connector's row"
```

---

### Task B3: Every connector names the policy its new tile starts from

**Files:**
- Modify: `Sources/PixelClockKit/Connectors/Connector.swift` (one requirement, one default)
- Modify: `Sources/PixelClockKit/Connectors/WeatherConnector.swift`, `ClaudeUsageConnector.swift`, `AnecdoteConnector.swift` (one property each)
- Create: `Tests/PixelClockTilesAppTests/ConnectorDefaultsTests.swift`

**Interfaces:**
- Consumes: `TileDefaults` (A8)
- Produces: `Connector.defaultPolicy: TilePolicy`. For a connector that names none, the default is exactly what the app-wide rules did to it before tiles. An audible one gets its own cadence, quiet under Do Not Disturb and Sleep, when the Focus cannot be named, and 23:00–08:00. A silent one gets its own cadence and nothing else, because the quiet rules were only ever asked of what could be heard. Weather, Claude and the anecdotes answer their `TileDefaults` rows. Production callers: B16 (the mapping's defaults) and B19 (a new tile).

**Template:** `AppModel.scheduleHold(for:)` as it stands before this phase: the quiet rules asked of audible connectors only. The default reproduces it, so every test double and every future connector that says nothing behaves exactly as it did.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockTilesAppTests/ConnectorDefaultsTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The defaults table reaches a tile through its connector. Each shipped
// connector answers its own row, and a row's refresh is the connector's own
// cadence, so a new tile runs as often as the connector always has.

private struct NoReading: ClaudeUsageReporting {
    func read() async throws -> ClaudeUsageReading? { nil }
}

private func shipped() -> [(connector: any Connector, row: TilePolicy)] {
    [
        (weatherConnector(over: StubTransport(body: Data())), TileDefaults.weather),
        (ClaudeUsageConnector(reporter: NoReading(), showsNow: { true }), TileDefaults.claude),
        (
            AppModel.anecdoteWiring(
                transport: StubTransport(body: Data()),
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("defaults-\(UUID().uuidString).json")
            ).connector,
            TileDefaults.anecdotes
        ),
    ]
}

@Test func eachShippedConnectorStartsItsTileFromItsOwnRow() {
    for (connector, row) in shipped() {
        #expect(connector.defaultPolicy == row, "\(connector.id)")
    }
}

@Test func aNewTileRunsAtItsConnectorsOwnCadence() {
    for (connector, _) in shipped() {
        #expect(connector.defaultPolicy.refresh == connector.defaultInterval, "\(connector.id)")
    }
}

// A connector that names nothing keeps what the app-wide rules did to it:
// held where they held an audible one, and nowhere if it cannot be heard.
@Test func anAudibleConnectorThatNamesNoPolicyKeepsTheOldQuietRules() {
    let policy = StubConnector().defaultPolicy

    #expect(policy.refresh == StubConnector().defaultInterval)
    #expect(policy.focus == FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold))
    #expect(policy.window == .quiet(HourWindow(startHour: 23, endHour: 8)))
}

@Test func aSilentConnectorThatNamesNoPolicyIsHeldByNothing() {
    #expect(silentConnector.defaultPolicy == TilePolicy(refreshSeconds: 900))
}
```

`weatherConnector(over:)` and `StubConnector` already exist in `Doubles.swift`. `AppModel.anecdoteWiring(transport:storeURL:)` already exists in `AppModel.swift`. Re-verify both, because Phase 2 touched their files.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ConnectorDefaultsTests`
Expected: FAIL. `value of type 'any Connector' has no member 'defaultPolicy'`.

- [ ] **Step 3: Implement.** In `Connector.swift`, add to the protocol, after `isAmbient`:

```swift
    /// The policy a new tile of this connector starts from: copied into the
    /// tile when it is made, and the tile's own from then on.
    var defaultPolicy: TilePolicy { get }
```

and to `extension Connector`:

```swift
    /// What a connector that names no policy starts from: exactly what the
    /// app-wide quiet rules did to it before tiles. Those were asked of an
    /// audible connector only — Do Not Disturb, Sleep, any Focus that could not
    /// be named, and the shipped 23:00–08:00 — and of a silent one never. So an
    /// undeclared connector behaves as it did, and it takes the recoverable
    /// direction `isAudible`'s own default takes.
    public var defaultPolicy: TilePolicy {
        guard isAudible else { return TilePolicy(refreshSeconds: Int(defaultInterval)) }
        return TilePolicy(
            refreshSeconds: Int(defaultInterval),
            focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold),
            window: .quiet(HourWindow(startHour: 23, endHour: 8))
        )
    }
```

Then one line in each shipped connector, beside its `defaultInterval`:

```swift
    public var defaultPolicy: TilePolicy { TileDefaults.weather }    // WeatherConnector
    public var defaultPolicy: TilePolicy { TileDefaults.claude }     // ClaudeUsageConnector
    public var defaultPolicy: TilePolicy { TileDefaults.anecdotes }  // AnecdoteConnector
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ConnectorDefaultsTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| delete `WeatherConnector.defaultPolicy` (it falls to the default) | `eachShippedConnectorStartsItsTileFromItsOwnRow` |
| `whenUnknown: .hold` → `.run` in the extension default | `anAudibleConnectorThatNamesNoPolicyKeepsTheOldQuietRules` |
| `guard isAudible else { … }` deleted | `aSilentConnectorThatNamesNoPolicyIsHeldByNothing` |
| A8's `claude` row `refreshSeconds: 300` → `600` | `aNewTileRunsAtItsConnectorsOwnCadence` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Connectors Tests/PixelClockTilesAppTests/ConnectorDefaultsTests.swift
git commit -m "feat: every connector names the policy its new tile starts from"
```

---

### Task B4: The VPN catalogue moves into the kit, with ids, names and lamp names

**Files:**
- Create: `Sources/PixelClockKit/VPN/WatchedVPN.swift`
- Modify: `Sources/PixelClockTilesApp/VPNPresence.swift` (the `WatchedVPN` struct goes; `import PixelClockKit` added)
- Modify: `Sources/PixelClockKit/Device/DeviceIndicator.swift` (append `IndicatorSlot.lampName`)
- Create: `Tests/PixelClockKitTests/WatchedVPNTests.swift`

**Interfaces:**
- Consumes: nothing new
- Produces: `public struct WatchedVPN: Sendable, Equatable` with `id`, `displayName`, `bundle`, `tunnelBinaries`, `pritunl`, `amnezia`, `catalogue` and `preset(id:)`; `IndicatorSlot.lampName` (`top` / `middle` / `bottom`). `VPNPresence.isUp(_:)` takes the kit type unchanged, and its 7 tests stay green without an edit.

**Template:** the app's `WatchedVPN`, moved verbatim with two fields added. The bundle and binary lists and their comments do not change.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/WatchedVPNTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Test func theCatalogueCarriesPritunlAndAmneziaUnderStableIds() {
    #expect(WatchedVPN.catalogue.map(\.id) == ["pritunl", "amnezia"])
    #expect(WatchedVPN.catalogue.map(\.displayName) == ["Pritunl", "Amnezia"])
    #expect(WatchedVPN.preset(id: "amnezia") == .amnezia)
    #expect(WatchedVPN.preset(id: "wireguard") == nil)
}

@Test func theLampsAreCalledWhereTheyAre() {
    #expect(IndicatorSlot.allCases.map(\.lampName) == ["top", "middle", "bottom"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WatchedVPNTests`
Expected: FAIL. `cannot find 'WatchedVPN' in scope` (it is internal to the app).

- [ ] **Step 3: Implement.** Create the kit file:

```swift
// Sources/PixelClockKit/VPN/WatchedVPN.swift
import Foundation

/// A VPN this app can watch, described by where its tunnel runs from.
///
/// Two fields rather than one name, because neither alone is enough: both apps
/// ship a binary called `wireguard-go`, and both keep a daemon running from
/// login to shutdown. The bundle says WHOSE process it is and the binary says
/// whether it is a tunnel — and the question needs both answers.
///
/// A catalogue entry rather than something a user describes: nobody can be
/// asked for a bundle path and a list of tunnel binaries, so a new VPN is added
/// here, in code.
public struct WatchedVPN: Sendable, Equatable {
    /// What a VPN tile stores to name its VPN, and its key's instance.
    public let id: String
    /// What the tile row, the tile detail and a lamp refusal call it.
    public let displayName: String
    /// The application bundle the process must have come out of.
    public let bundle: String
    /// The binaries that exist only while a tunnel is up.
    ///
    /// Deliberately not the app itself and not its service: `pritunl-service`
    /// and `AmneziaVPN-service` are started with the login session and run with
    /// nothing connected. They are what ACCEPTS a connection rather than what
    /// is one, and a detector that watched them would report both VPNs up from
    /// the moment the Mac finished booting.
    public let tunnelBinaries: Set<String>

    public static let pritunl = WatchedVPN(
        id: "pritunl",
        displayName: "Pritunl",
        bundle: "/Applications/Pritunl.app/",
        tunnelBinaries: ["pritunl-openvpn", "pritunl-openvpn10", "wireguard-go"]
    )

    /// Amnezia carries a tunnel over whichever protocol its profile selects,
    /// and the user can change that without this app being told — so the set is
    /// the protocol list, not one name.
    public static let amnezia = WatchedVPN(
        id: "amnezia",
        displayName: "Amnezia",
        bundle: "/Applications/AmneziaVPN.app/",
        tunnelBinaries: [
            "wireguard-go", "openvpn", "tun2socks", "ck-client", "ss-local", "ss-tunnel",
        ]
    )

    /// Every VPN a tile can watch, in the order the tile detail offers them.
    public static let catalogue: [WatchedVPN] = [.pritunl, .amnezia]

    public static func preset(id: String) -> WatchedVPN? {
        catalogue.first { $0.id == id }
    }
}
```

In `Sources/PixelClockTilesApp/VPNPresence.swift`, delete `struct WatchedVPN` (its doc comment included) and add `import PixelClockKit` after `import Foundation`. Append to `Sources/PixelClockKit/Device/DeviceIndicator.swift`:

```swift
extension IndicatorSlot {
    /// What the settings and a lamp refusal call it — top, middle, bottom.
    public var lampName: String {
        switch self {
        case .topRight: "top"
        case .middleRight: "middle"
        case .bottomRight: "bottom"
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter 'WatchedVPNTests|VPNPresenceTests|VPNIndicatorWiringTests'`
Expected: PASS. 2 new tests, and the existing VPN tests unchanged.

- [ ] **Step 5: Mutate.** `case .middleRight: "middle"` → `"centre"`. `theLampsAreCalledWhereTheyAre` must fail.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/VPN/WatchedVPN.swift Sources/PixelClockKit/Device/DeviceIndicator.swift Sources/PixelClockTilesApp/VPNPresence.swift Tests/PixelClockKitTests/WatchedVPNTests.swift
git commit -m "refactor: the VPN catalogue moves into the kit, with ids and names"
```

---

### Task B5: The VPN tile's config and its stored shape

**Files:**
- Create: `Sources/PixelClockKit/VPN/VPNTileConfig.swift`
- Create: `Tests/PixelClockKitTests/VPNTileConfigTests.swift`

**Interfaces:**
- Consumes: `IndicatorSlot.lampName` (B4)
- Produces: `public struct VPNTileConfig: Equatable, Sendable, Codable` with `vpn` (a `WatchedVPN.id`), `slot`, `upColour`, `whenDown: .off | .blink(String)` and `blinkMilliseconds = 500`. The shape is under [Persisted shapes](#persisted-shapes-reconciled-with-phase-1).

**Template:** `TileWindow`'s hand-written coding (A7): a `kind` key, and the payload beside it.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/VPNTileConfigTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private let pritunlLamp = VPNTileConfig(
    vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000")
)
private let amneziaLamp = VPNTileConfig(
    vpn: "amnezia", slot: .bottomRight, upColour: "#A855F7", whenDown: .off
)

@Test func aVPNTileConfigIsWrittenInTheDocumentedShape() throws {
    #expect(try json(pritunlLamp) == """
    {"slot":"top","upColour":"#90EE90","vpn":"pritunl",\
    "whenDown":{"colour":"#FF0000","kind":"blink"}}
    """)
    #expect(try json(amneziaLamp) == """
    {"slot":"bottom","upColour":"#A855F7","vpn":"amnezia","whenDown":{"kind":"off"}}
    """)
}

@Test func aVPNTileConfigSurvivesARoundTrip() throws {
    for config in [pritunlLamp, amneziaLamp] {
        let data = Data(try json(config).utf8)
        #expect(try JSONDecoder().decode(VPNTileConfig.self, from: data) == config)
    }
}

@Test func aLampThisClockDoesNotHaveIsRefused() {
    let text = ##"{"slot":"left","upColour":"#FFFFFF","vpn":"pritunl","whenDown":{"kind":"off"}}"##
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(VPNTileConfig.self, from: Data(text.utf8))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter VPNTileConfigTests`
Expected: FAIL. `cannot find 'VPNTileConfig' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/PixelClockKit/VPN/VPNTileConfig.swift
import Foundation

/// What one VPN tile needs that no other tile does.
///
/// Persisted shape, written by hand so nothing on disk moves with a rename:
///
///   {"slot":"top","upColour":"#90EE90","vpn":"pritunl",
///    "whenDown":{"colour":"#FF0000","kind":"blink"}}
///
/// `whenDown` is `{"kind":"off"}` for a lamp that goes dark with its tunnel.
public struct VPNTileConfig: Equatable, Sendable {
    public enum WhenDown: Equatable, Sendable {
        case off
        case blink(String)
    }

    /// Twice a second — fast enough to catch an eye that is not looking at the
    /// clock, slow enough not to strobe a dark room.
    public static let blinkMilliseconds = 500

    /// A `WatchedVPN.id`.
    public var vpn: String
    public var slot: IndicatorSlot
    /// `#RRGGBB`.
    public var upColour: String
    public var whenDown: WhenDown

    public init(vpn: String, slot: IndicatorSlot, upColour: String, whenDown: WhenDown) {
        self.vpn = vpn
        self.slot = slot
        self.upColour = upColour
        self.whenDown = whenDown
    }
}

extension VPNTileConfig: Codable {
    private enum Key: String, CodingKey {
        case vpn, slot, upColour, whenDown
    }

    private enum DownKey: String, CodingKey {
        case kind, colour
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let lamp = try container.decode(String.self, forKey: .slot)
        guard let slot = IndicatorSlot.allCases.first(where: { $0.lampName == lamp }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .slot, in: container, debugDescription: "no lamp called \(lamp)"
            )
        }
        let down = try container.nestedContainer(keyedBy: DownKey.self, forKey: .whenDown)
        let whenDown: WhenDown
        switch try down.decode(String.self, forKey: .kind) {
        case "off":
            whenDown = .off
        case "blink":
            whenDown = .blink(try down.decode(String.self, forKey: .colour))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: down, debugDescription: "no down behaviour called \(other)"
            )
        }
        self.init(
            vpn: try container.decode(String.self, forKey: .vpn),
            slot: slot,
            upColour: try container.decode(String.self, forKey: .upColour),
            whenDown: whenDown
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(vpn, forKey: .vpn)
        try container.encode(slot.lampName, forKey: .slot)
        try container.encode(upColour, forKey: .upColour)
        var down = container.nestedContainer(keyedBy: DownKey.self, forKey: .whenDown)
        switch whenDown {
        case .off:
            try down.encode("off", forKey: .kind)
        case let .blink(colour):
            try down.encode("blink", forKey: .kind)
            try down.encode(colour, forKey: .colour)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter VPNTileConfigTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Mutate.** Delete `try down.encode(colour, forKey: .colour)`. `aVPNTileConfigIsWrittenInTheDocumentedShape` must fail.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/VPN/VPNTileConfig.swift Tests/PixelClockKitTests/VPNTileConfigTests.swift
git commit -m "feat: the VPN tile's config and its stored shape"
```

---

### Task B6: A tile's settings, stored beside its policy

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TileConfig.swift`
- Modify: `Sources/PixelClockKit/Tiles/TileRecord.swift` (`TileRecord.config`)
- Create: `Tests/PixelClockKitTests/TileConfigTests.swift`

**Interfaces:**
- Consumes: `Coordinates`, `VPNTileConfig` (B5)
- Produces: `public enum TileConfig: Equatable, Sendable, Codable { case weather(Coordinates), vpn(VPNTileConfig) }` with `location` and `lamp`; `TileRecord.config: TileConfig?`, whose `init` gains `config: TileConfig? = nil`. Production callers: B7 (weather) and B18 (VPN).

**Template:** `TileWindow`'s coding (A7). Here there is one key per connector and no `kind`, because each case carries a whole object.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/TileConfigTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

private let moscow = Coordinates(latitude: 55.7558, longitude: 37.6173)
private let pritunl = VPNTileConfig(
    vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000")
)

@Test func aTileConfigIsStoredUnderTheConnectorItBelongsTo() throws {
    #expect(try json(TileConfig.weather(moscow)) == #"{"weather":{"latitude":55.7558,"longitude":37.6173}}"#)
    #expect(try json(TileConfig.vpn(pritunl)) == """
    {"vpn":{"slot":"top","upColour":"#90EE90","vpn":"pritunl",\
    "whenDown":{"colour":"#FF0000","kind":"blink"}}}
    """)
}

@Test func aTileConfigSurvivesARoundTrip() throws {
    for config in [TileConfig.weather(moscow), .vpn(pritunl)] {
        #expect(try decoded(TileConfig.self, try json(config)) == config)
    }
}

@Test func aConfigNamingTwoConnectorsIsRefused() {
    let both = ##"{"weather":{"latitude":1,"longitude":2},"vpn":{"slot":"top","upColour":"#FFFFFF","vpn":"pritunl","whenDown":{"kind":"off"}}}"##
    #expect(throws: DecodingError.self) { _ = try decoded(TileConfig.self, both) }
    #expect(throws: DecodingError.self) { _ = try decoded(TileConfig.self, "{}") }
}

@Test func eachConfigAnswersOnlyForItsOwnConnector() {
    #expect(TileConfig.weather(moscow).location == moscow)
    #expect(TileConfig.weather(moscow).lamp == nil)
    #expect(TileConfig.vpn(pritunl).lamp == pritunl)
    #expect(TileConfig.vpn(pritunl).location == nil)
}

// Phase 1's records carry no config, and they still decode.
@Test func aTileWithoutAConfigStillDecodes() throws {
    let text = """
    {"key":{"clockId":"8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F","connectorId":"claude","instance":""},\
    "policy":{"isPaused":false,"refreshSeconds":300}}
    """
    let tile = try decoded(TileRecord.self, text)

    #expect(tile.config == nil)
    #expect(try json(tile).contains("config") == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TileConfigTests`
Expected: FAIL. `cannot find 'TileConfig' in scope`.

- [ ] **Step 3: Implement.** In Phase 1's `TileRecord`, after `lastDeliveredAt`:

```swift
    /// What this tile needs that no other tile does, or nil for a connector
    /// that needs nothing. Optional, so every record Phase 1 wrote decodes.
    public var config: TileConfig?
```

and extend its `init` with `config: TileConfig? = nil` (assigned last). Then:

```swift
// Sources/PixelClockKit/Tiles/TileConfig.swift
import Foundation

/// What one tile needs that no other tile does: the weather tile's place, the
/// VPN tile's VPN, lamp and colours.
///
/// Closed, like the connectors themselves: a connector is a type in code, so
/// the settings it can have are known in code too. Stored under one key naming
/// the connector it belongs to:
///
///   {"weather":{"latitude":55.7558,"longitude":37.6173}}
///   {"vpn":{"slot":"top","upColour":"#90EE90","vpn":"pritunl",
///           "whenDown":{"colour":"#FF0000","kind":"blink"}}}
public enum TileConfig: Equatable, Sendable {
    case weather(Coordinates)
    case vpn(VPNTileConfig)

    /// The weather tile's place, or nil for any other tile.
    public var location: Coordinates? {
        guard case let .weather(place) = self else { return nil }
        return place
    }

    /// The VPN tile's lamp, or nil for any other tile.
    public var lamp: VPNTileConfig? {
        guard case let .vpn(lamp) = self else { return nil }
        return lamp
    }
}

extension TileConfig: Codable {
    private enum Key: String, CodingKey {
        case weather, vpn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        // Exactly one key. Two would be a tile claiming two connectors' settings,
        // and picking one of them would be a guess about which it is.
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "a tile config names exactly one connector"
            ))
        }
        switch key {
        case .weather:
            self = .weather(try container.decode(Coordinates.self, forKey: .weather))
        case .vpn:
            self = .vpn(try container.decode(VPNTileConfig.self, forKey: .vpn))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .weather(place):
            try container.encode(place, forKey: .weather)
        case let .vpn(lamp):
            try container.encode(lamp, forKey: .vpn)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter 'TileConfigTests|TileStoreTests'`
Expected: PASS. 5 new tests, and Phase 1's store tests unchanged.

- [ ] **Step 5: Mutate.** `guard container.allKeys.count == 1, let key` → `guard let key`. `aConfigNamingTwoConnectorsIsRefused` must fail.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TileConfig.swift Sources/PixelClockKit/Tiles/TileRecord.swift Tests/PixelClockKitTests/TileConfigTests.swift
git commit -m "feat: a tile's own settings, stored beside its policy"
```

---

### Task B7: The weather tile carries its place — and `weatherLocation` migrates

The reader and the migration step land together. From this commit on, the weather reads the place off the tile and the settings field writes it there, so `weatherLocation` is no longer written (Phase 1 D3).

**Files:**
- Create: `Sources/PixelClockTilesApp/WeatherLocationMigration.swift`
- Create: `Tests/PixelClockTilesAppTests/MigrationFixtures.swift`, `Tests/PixelClockTilesAppTests/WeatherLocationMigrationTests.swift`, `Tests/PixelClockTilesAppTests/WeatherTilePlaceTests.swift`
- Modify: `Sources/PixelClockTilesApp/LocationField.swift` (`StoredLocation` reads and writes the tile; `Coordinates.stored(in:)`, `save(to:)` and `storageKey` are deleted)
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`live()`: run the step, then build `StoredLocation(defaults:clockId:)`; `init`: `typedLocation` reads and saves through it)
- Modify: `Tests/PixelClockTilesAppTests/AppShellTests.swift` (the 4 `Coordinates.stored(in:)` reads)

**Interfaces:**
- Consumes: `TileStore`, `ClockRecord.id` (Phase 1); `TileConfig.weather` (B6); `Coordinates.default` (app)
- Produces: `struct WeatherLocationMigration { static let markerKey = "migration.weatherLocation"; static let legacyKey = "weatherLocation"; let defaults: UserDefaults; func run() throws }`; `final class StoredLocation { init(defaults:clockId:); var current: Coordinates; func save(_:) }`; `LocationField.save(_ typed: String, to place: StoredLocation) -> String`

**Template:** Phase 1's `TileMigration`: marker guard, one `replaceAll`, marker last. Also `StoredLocation`, whose read-on-every-produce rule is kept.

- [ ] **Step 1: Write the shared fixtures and the failing migration tests**

```swift
// Tests/PixelClockTilesAppTests/MigrationFixtures.swift
import Foundation
import PixelClockKit
import Testing

/// Runs `body` against a defaults domain of its own, which is gone afterwards.
func withFreshDefaults(_ body: (RecordingDefaults) throws -> Void) throws {
    let suite = "migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

/// The clock `ClockMigration` leaves behind, stored.
@discardableResult
func storeAClock(
    _ model: ClockModel = .awtrix3, in defaults: UserDefaults
) throws -> ClockRecord {
    let clock = ClockRecord(name: "Clock", model: model, address: "10.0.0.9")
    try ClockStore(defaults: defaults).replaceAll([clock])
    return clock
}

/// The tiles `TileMigration` leaves behind on that clock: the three shipped
/// connectors, as Phase 1 stores them — no Focus, no hours, no config.
func storeTheMigratedTiles(on clock: ClockRecord, in defaults: UserDefaults) throws {
    try TileStore(defaults: defaults).replaceAll([
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: "anecdotes"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 1_800)
        ),
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: "weather"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
        ),
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: "claude"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 300)
        ),
    ])
}

func tile(_ connectorId: String, in defaults: UserDefaults) -> TileRecord? {
    TileStore(defaults: defaults).all().first { $0.key.connectorId == connectorId }
}
```

```swift
// Tests/PixelClockTilesAppTests/WeatherLocationMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let tbilisi = Coordinates(latitude: 41.7151, longitude: 44.8271)

private func savedTheOldWay(_ place: Coordinates, in defaults: UserDefaults) throws {
    defaults.set(try JSONEncoder().encode(place), forKey: WeatherLocationMigration.legacyKey)
}

@Test func theSavedPlaceBecomesTheWeatherTilesConfig() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try savedTheOldWay(tbilisi, in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("weather", in: defaults)?.config == .weather(tbilisi))
    }
}

// Never saved is the place the app was reading for all along.
@Test func aPlaceNeverSavedIsThePlaceTheAppWasUsing() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("weather", in: defaults)?.config == .weather(.default))
    }
}

@Test func noOtherTileGainsAPlace() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try savedTheOldWay(tbilisi, in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("anecdotes", in: defaults)?.config == nil)
        #expect(tile("claude", in: defaults)?.config == nil)
    }
}

@Test func theWeatherLocationMigrationLeavesTheOldKeyAsItWas() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try savedTheOldWay(tbilisi, in: defaults)
        let before = defaults.data(forKey: WeatherLocationMigration.legacyKey)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: WeatherLocationMigration.legacyKey) == before)
    }
}

@Test func theWeatherLocationMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(defaults.writes.last == WeatherLocationMigration.markerKey)
    }
}

// Run again after the user moved the tile somewhere else: the tile keeps the
// place the user gave it.
@Test func aSecondWeatherLocationMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try WeatherLocationMigration(defaults: defaults).run()
        let moved = try #require(tile("weather", in: defaults))
        TileStore(defaults: defaults).update(moved) { $0.config = .weather(tbilisi) }

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("weather", in: defaults)?.config == .weather(tbilisi))
    }
}
```

```swift
// Tests/PixelClockTilesAppTests/WeatherTilePlaceTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let berlin = Coordinates(latitude: 52.52, longitude: 13.405)

@Test func theWeatherReadsThePlaceOnItsClocksWeatherTile() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)
        let tile = try #require(tile("weather", in: defaults))
        TileStore(defaults: defaults).update(tile) { $0.config = .weather(berlin) }

        #expect(StoredLocation(defaults: defaults, clockId: clock.id).current == berlin)
    }
}

@Test func aWeatherTileWithNoPlaceReadsTheDefaultOne() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)

        #expect(StoredLocation(defaults: defaults, clockId: clock.id).current == .default)
    }
}

@Test func aTypedPlaceIsSavedOnTheWeatherTileAndNowhereElse() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)

        StoredLocation(defaults: defaults, clockId: clock.id).save(berlin)

        #expect(tile("weather", in: defaults)?.config == .weather(berlin))
        #expect(defaults.data(forKey: WeatherLocationMigration.legacyKey) == nil)
    }
}

// Saving a place must not bring back a weather tile the user removed.
@Test func savingAPlaceOnAClockWithNoWeatherTileAddsNone() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)

        StoredLocation(defaults: defaults, clockId: clock.id).save(berlin)

        #expect(TileStore(defaults: defaults).all().isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'WeatherLocationMigrationTests|WeatherTilePlaceTests'`
Expected: FAIL. `cannot find 'WeatherLocationMigration' in scope`, and `extra argument 'clockId'`.

- [ ] **Step 3: Implement the step**

```swift
// Sources/PixelClockTilesApp/WeatherLocationMigration.swift
import Foundation
import PixelClockKit

/// Puts the one place the weather was read for onto the weather tiles.
///
/// Runs once, marker last, old key only read — the terms of `ClockMigration`.
/// A key never written, or one that does not decode, is the place the app was
/// using all along, `Coordinates.default`, and that is what is copied.
struct WeatherLocationMigration {
    static let markerKey = "migration.weatherLocation"
    static let legacyKey = "weatherLocation"

    let defaults: UserDefaults

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        let place = defaults.data(forKey: Self.legacyKey)
            .flatMap { try? JSONDecoder().decode(Coordinates.self, from: $0) } ?? .default
        let store = TileStore(defaults: defaults)
        try store.replaceAll(store.all().map { tile in
            guard tile.key.connectorId == "weather" else { return tile }
            var placed = tile
            placed.config = .weather(place)
            return placed
        })
        defaults.set(true, forKey: Self.markerKey)
    }
}
```

- [ ] **Step 4: Move the reader and the writer onto the tile.** In `LocationField.swift`, delete `static let storageKey`, `static func stored(in:)` and `func save(to:)` from `extension Coordinates`, and keep `default`. Replace `StoredLocation` with:

```swift
/// The place one clock's weather tile reads for.
///
/// Read on every produce rather than captured, so a place typed into the
/// settings takes effect at the next poll. The tile is looked up each time
/// for the same reason: it is the record, and a copy would go stale.
final class StoredLocation: @unchecked Sendable {
    private let defaults: UserDefaults
    private let clockId: UUID

    init(defaults: UserDefaults, clockId: UUID) {
        self.defaults = defaults
        self.clockId = clockId
    }

    var current: Coordinates { weatherTile?.config?.location ?? .default }

    /// Onto the tile, and only onto one that exists: saving a place is not a
    /// way to put back a weather tile the user took off the clock.
    func save(_ place: Coordinates) {
        guard let tile = weatherTile else { return }
        TileStore(defaults: defaults).update(tile) { $0.config = .weather(place) }
    }

    private var weatherTile: TileRecord? {
        TileStore(defaults: defaults).all().first {
            $0.key == TileKey(clockId: clockId, connectorId: WeatherConnector.appName)
        }
    }
}
```

In `enum LocationField`, change `save(_ typed: String, to defaults: UserDefaults)` to `save(_ typed: String, to place: StoredLocation)`, and its `place.save(to: defaults)` line to `place.save(parsed)`, renaming its local `place` to `parsed`. `WeatherConnector.appName` is `"weather"`, which is also its `id`.

In `AppModel`:
- `live()`: directly after `TileMigration(…).run()`, add `try? WeatherLocationMigration(defaults: defaults).run()`, in the same `try?` style Phase 1 used for its two steps. Replace `let location = StoredLocation(defaults: defaults)` with `let location = StoredLocation(defaults: defaults, clockId: clock.id)`.
- `init`: add `private let location: StoredLocation`, built as `StoredLocation(defaults: defaults, clockId: clock.id)`. `typedLocation`'s initial value becomes `LocationField.text(for: location.current)`, and its `didSet` becomes `locationNote = LocationField.save(typedLocation, to: location)`.

In `AppShellTests.swift`, the four `Coordinates.stored(in: defaults)` reads become `StoredLocation(defaults: defaults, clockId: <the model's clock id>).current`. The storage read moved and the assertions do not change, in the same way Phase 1 T3 moved seven such reads.

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter 'WeatherLocationMigrationTests|WeatherTilePlaceTests|AppShellTests|RecordWiringTests'`
Expected: PASS. 10 new tests.

- [ ] **Step 6: Mutate, one site at a time** (the marker guard sits in front of everything, so its row runs last)

| Mutation | Must fail |
| --- | --- |
| delete `guard tile.key.connectorId == "weather" else { return tile }` | `noOtherTileGainsAPlace` |
| `?? .default` → `?? Coordinates(latitude: 0, longitude: 0)` in the step | `aPlaceNeverSavedIsThePlaceTheAppWasUsing` |
| delete `guard let tile = weatherTile else { return }` in `StoredLocation.save` | `savingAPlaceOnAClockWithNoWeatherTileAddsNone` |
| swap the step's last two lines | `theWeatherLocationMigrationWritesItsMarkerLast` |
| delete the marker guard | `aSecondWeatherLocationMigrationChangesNothing` |

- [ ] **Step 7: Commit**

```bash
git add Sources/PixelClockTilesApp/WeatherLocationMigration.swift Sources/PixelClockTilesApp/LocationField.swift Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/MigrationFixtures.swift Tests/PixelClockTilesAppTests/WeatherLocationMigrationTests.swift Tests/PixelClockTilesAppTests/WeatherTilePlaceTests.swift Tests/PixelClockTilesAppTests/AppShellTests.swift
git commit -m "feat: the weather tile carries its place, migrated from weatherLocation"
```

---

### Task B8: The VPN connector — one tile per VPN, a lamp face and no TC002 face

**Files:**
- Create: `Sources/PixelClockKit/VPN/VPNConnector.swift`
- Create: `Tests/PixelClockKitTests/VPNConnectorTests.swift`

**Interfaces:**
- Consumes: `WatchedVPN` (B4), `VPNTileConfig` (B5)
- Produces: `VPNReading { isUp, lamp }`, `VPNConnectorError.unknownVPN`, and `public struct VPNConnector: Sendable` with `static let id = "vpn"`, `displayName`, `init(isUp:)`, `read(config:)` and `static func signal(for:) -> IndicatorSignal`. It is **not** a `Connector` (decision 9). Production caller: B18.

**Template:** `VPNIndicatorPolicy.lamps(focus:pritunl:amnezia:)`: the up/down half of it. The Focus half is the tile policy's now.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/VPNConnectorTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private let pritunlLamp = VPNTileConfig(
    vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000")
)
private let amneziaLamp = VPNTileConfig(
    vpn: "amnezia", slot: .bottomRight, upColour: "#A855F7", whenDown: .off
)

@Test func upIsTheTilesColourSteady() {
    #expect(VPNConnector.signal(for: VPNReading(isUp: true, lamp: pritunlLamp)) == .steady("#90EE90"))
}

@Test func downIsDarkOrABlinkAsTheTileSays() {
    #expect(VPNConnector.signal(for: VPNReading(isUp: false, lamp: amneziaLamp)) == .off)
    #expect(
        VPNConnector.signal(for: VPNReading(isUp: false, lamp: pritunlLamp))
            == .blinking("#FF0000", everyMilliseconds: 500)
    )
}

@Test func theReadingAsksAboutTheTilesOwnVPN() async throws {
    let asked = Asked()
    let connector = VPNConnector { vpn in asked.record(vpn.id); return vpn == .amnezia }

    let reading = try await connector.read(config: amneziaLamp)

    #expect(reading == VPNReading(isUp: true, lamp: amneziaLamp))
    #expect(asked.ids == ["amnezia"])
}

// A preset gone from the catalogue is a failed read, not a dark lamp that
// says "down" about a VPN nobody can watch any more.
@Test func aVPNTheCatalogueNoLongerCarriesIsAFailedReadNotADarkLamp() async {
    var gone = pritunlLamp
    gone.vpn = "wireguard"

    await #expect(throws: VPNConnectorError.unknownVPN("wireguard")) {
        _ = try await VPNConnector(isUp: { _ in false }).read(config: gone)
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var ids: [String] { lock.withLock { recorded } }
    func record(_ id: String) { lock.withLock { recorded.append(id) } }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter VPNConnectorTests`
Expected: FAIL. `cannot find 'VPNConnector' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/PixelClockKit/VPN/VPNConnector.swift
import Foundation

/// One watched VPN, read for one tile, with the lamp it is to be shown on.
///
/// The config travels with the reading so the face stays a function of the
/// reading alone: which lamp, and in which colours, is the tile's to say, and
/// the face has nothing else to ask.
public struct VPNReading: Equatable, Sendable {
    public let isUp: Bool
    public let lamp: VPNTileConfig

    public init(isUp: Bool, lamp: VPNTileConfig) {
        self.isUp = isUp
        self.lamp = lamp
    }
}

public enum VPNConnectorError: Error, Equatable, Sendable {
    /// The tile names a VPN the catalogue no longer carries.
    case unknownVPN(String)
}

/// Whether a VPN is up, on one of the clock's corner lamps.
///
/// Not a `Connector`: a lamp is not a scene. It is written straight to the
/// clock's `IndicatorCustody`, off the delivery chain, so a lamp never waits
/// behind a playing anecdote — and who owns a shared lamp at this moment is
/// decided across tiles (`LampBoard`), which no per-tile face could do. One
/// tile per VPN, keyed by `WatchedVPN.id`. How the machine is asked is
/// injected: the process table is the app's to read.
public struct VPNConnector: Sendable {
    public static let id = "vpn"
    public var id: String { Self.id }
    public let displayName = "VPN"

    private let isUp: @Sendable (WatchedVPN) -> Bool

    public init(isUp: @escaping @Sendable (WatchedVPN) -> Bool) {
        self.isUp = isUp
    }

    public func read(config: VPNTileConfig) async throws -> VPNReading {
        guard let vpn = WatchedVPN.preset(id: config.vpn) else {
            throw VPNConnectorError.unknownVPN(config.vpn)
        }
        return VPNReading(isUp: isUp(vpn), lamp: config)
    }

    /// The AWTRIX face of a lamp: up is the tile's colour, steady; down is
    /// dark or a blink, as the tile says. The blink belongs to the firmware,
    /// so it costs one write and keeps going with this app asleep. There is no
    /// TC002 face — that clock has no lamps of its own.
    public static func signal(for reading: VPNReading) -> IndicatorSignal {
        if reading.isUp { return .steady(reading.lamp.upColour) }
        switch reading.lamp.whenDown {
        case .off:
            return .off
        case let .blink(colour):
            return .blinking(colour, everyMilliseconds: VPNTileConfig.blinkMilliseconds)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter VPNConnectorTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| delete `if reading.isUp { return .steady(reading.lamp.upColour) }` | `upIsTheTilesColourSteady` |
| `case .off: return .off` → `return .blinking(reading.lamp.upColour, everyMilliseconds: 500)` | `downIsDarkOrABlinkAsTheTileSays` |
| replace the `guard let vpn = WatchedVPN.preset(…) else { throw … }` with `let vpn = WatchedVPN.preset(id: config.vpn) ?? .pritunl` | `aVPNTheCatalogueNoLongerCarriesIsAFailedReadNotADarkLamp` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/VPN/VPNConnector.swift Tests/PixelClockKitTests/VPNConnectorTests.swift
git commit -m "feat: a VPN connector — one tile per VPN, a lamp face and no TC002 face"
```

---

### Task B9: One owner per lamp at a time, resolved before anything is written

**Files:**
- Create: `Sources/PixelClockKit/VPN/LampBoard.swift`
- Create: `Tests/PixelClockKitTests/LampBoardTests.swift`

**Interfaces:**
- Consumes: `TilePolicy.runs(in:atHour:)` (A6), `TileKey` (Phase 1)
- Produces: `LampClaim { key, slot, policy, signal }` and `LampBoard.lamps(_:covering:in:atHour:) -> [IndicatorSlot: IndicatorSignal]`. Production caller: B18.

**Template:** `VPNIndicatorPolicy.lamps`, a pure function of the Focus and the tunnels that answers both corners at once. Its six tests are **ported here under the same names**. The rule they pin moved from one function of the Focus into each tile's policy. The claims are the two tiles B18's migration writes.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/LampBoardTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The two lamps the migration makes out of today's always-on corners, asked
// the questions `VPNIndicatorPolicyTests` asked of the policy they replace.
// Same names, same answers — the rule moved from one function of the Focus into
// each tile's own policy.

private let desk = UUID()

private func policy(workingIn focuses: Set<MacFocus>) -> TilePolicy {
    TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(
            silencedIn: Set(MacFocus.allCases).subtracting(focuses).subtracting([.unknown]),
            whenUnknown: .hold
        )
    )
}

private func pritunl(up: Bool) -> LampClaim {
    LampClaim(
        key: TileKey(clockId: desk, connectorId: "vpn", instance: "pritunl"),
        slot: .topRight,
        policy: policy(workingIn: [.work]),
        signal: up ? .steady("#90EE90") : .blinking("#FF0000", everyMilliseconds: 500)
    )
}

private func amnezia(up: Bool) -> LampClaim {
    LampClaim(
        key: TileKey(clockId: desk, connectorId: "vpn", instance: "amnezia"),
        slot: .bottomRight,
        policy: policy(workingIn: [.work, .personal]),
        signal: up ? .steady("#A855F7") : .off
    )
}

private func lamps(_ claims: [LampClaim], in focus: MacFocus) -> [IndicatorSlot: IndicatorSignal] {
    LampBoard.lamps(claims, in: focus, atHour: 12)
}

@Test func workWithoutItsTunnelBlinksTheTopCorner() {
    let shown = lamps([pritunl(up: false), amnezia(up: false)], in: .work)

    #expect(shown[.topRight] == .blinking("#FF0000", everyMilliseconds: 500))
}

@Test func workWithItsTunnelGoesQuietlyGreen() {
    #expect(lamps([pritunl(up: true), amnezia(up: false)], in: .work)[.topRight] == .steady("#90EE90"))
}

@Test func thePersonalTunnelIsWatchedUnderBothFocuses() {
    for focus: MacFocus in [.work, .personal] {
        #expect(lamps([pritunl(up: false), amnezia(up: true)], in: focus)[.bottomRight] == .steady("#A855F7"))
    }
}

@Test func personalFocusSaysNothingAboutTheWorkTunnel() {
    for up in [false, true] {
        #expect(lamps([pritunl(up: up), amnezia(up: true)], in: .personal)[.topRight] == .off)
    }
}

@Test func everyOtherFocusLeavesBothCornersDark() {
    for focus: MacFocus in [.noFocus, .doNotDisturb, .sleep] {
        #expect(
            lamps([pritunl(up: false), amnezia(up: true)], in: focus)
                == [.topRight: .off, .bottomRight: .off],
            "\(focus)"
        )
    }
}

@Test func aFocusThatCannotBeNamedClaimsNothing() {
    #expect(
        lamps([pritunl(up: false), amnezia(up: true)], in: .unknown)
            == [.topRight: .off, .bottomRight: .off]
    )
}

// MARK: - Sharing a lamp

private func other(on slot: IndicatorSlot, workingIn focuses: Set<MacFocus>) -> LampClaim {
    LampClaim(
        key: TileKey(clockId: desk, connectorId: "vpn", instance: "other"),
        slot: slot,
        policy: policy(workingIn: focuses),
        signal: .steady("#00F0FF")
    )
}

@Test func aSharedLampBelongsToWhicheverTileRunsNow() {
    let claims = [pritunl(up: true), other(on: .topRight, workingIn: [.personal])]

    #expect(lamps(claims, in: .work)[.topRight] == .steady("#90EE90"))
    #expect(lamps(claims, in: .personal)[.topRight] == .steady("#00F0FF"))
    #expect(lamps(claims, in: .noFocus)[.topRight] == .off)
}

@Test func whenTwoClaimsRunAtOnceTheFirstHoldsTheLamp() {
    let claims = [pritunl(up: true), other(on: .topRight, workingIn: [.work])]

    #expect(lamps(claims, in: .work)[.topRight] == .steady("#90EE90"))
    #expect(lamps(claims.reversed(), in: .work)[.topRight] == .steady("#00F0FF"))
}

// A lamp nobody claims is somebody else's — another integration may be using
// the middle one — so it is not written at all.
@Test func onlyTheLampsInPlayAreAnswered() {
    #expect(Set(lamps([pritunl(up: true)], in: .work).keys) == [.topRight])
}

@Test func aLampWhoseLastClaimWentAwayIsPutOut() {
    let shown = LampBoard.lamps([], covering: [.middleRight], in: .work, atHour: 12)

    #expect(shown == [.middleRight: .off])
}

@Test func theHoursDecideTooNotOnlyTheFocus() {
    var office = pritunl(up: true)
    office = LampClaim(
        key: office.key, slot: office.slot,
        policy: TilePolicy(refreshSeconds: 60, window: .active(HourWindow(startHour: 10, endHour: 19))),
        signal: office.signal
    )

    #expect(LampBoard.lamps([office], in: .work, atHour: 9)[.topRight] == .off)
    #expect(LampBoard.lamps([office], in: .work, atHour: 10)[.topRight] == .steady("#90EE90"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LampBoardTests`
Expected: FAIL. `cannot find 'LampClaim' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/PixelClockKit/VPN/LampBoard.swift
import Foundation

/// One VPN tile's bid for its lamp.
public struct LampClaim: Equatable, Sendable {
    public let key: TileKey
    public let slot: IndicatorSlot
    public let policy: TilePolicy
    /// What the tile's face shows for its latest reading.
    public let signal: IndicatorSignal

    public init(key: TileKey, slot: IndicatorSlot, policy: TilePolicy, signal: IndicatorSignal) {
        self.key = key
        self.slot = slot
        self.policy = policy
        self.signal = signal
    }
}

/// Who owns each lamp of one clock at this moment.
public enum LampBoard {
    /// Every slot named by a claim or in `covering`, and what it shows: the
    /// signal of the first claim whose policy runs now, or `.off` when none
    /// does.
    ///
    /// One answer per slot, worked out before anything is written. A lamp
    /// handed from one tile to another on a Focus switch therefore goes
    /// straight from the old colour to the new one, never through the old tile
    /// letting go first.
    ///
    /// Only the slots in play. A lamp no VPN tile has claimed is left to
    /// whatever else lit it; `covering` names the ones this app lit before and
    /// must now put out, because their last claim went away.
    ///
    /// "First" is a tie-break for a state the save-time refusal keeps out —
    /// two claims on one lamp running at once — so that if one ever arrives,
    /// by a migration or a hand-edited file, the lamp shows one steady answer
    /// rather than whichever write landed last.
    public static func lamps(
        _ claims: [LampClaim],
        covering: Set<IndicatorSlot> = [],
        in focus: MacFocus,
        atHour hour: Int
    ) -> [IndicatorSlot: IndicatorSignal] {
        let slots = covering.union(claims.map(\.slot))
        return Dictionary(uniqueKeysWithValues: slots.map { slot in
            let owner = claims.first { $0.slot == slot && $0.policy.runs(in: focus, atHour: hour) }
            return (slot, owner?.signal ?? .off)
        })
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LampBoardTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `$0.slot == slot && $0.policy.runs(…)` → `$0.slot == slot` | `personalFocusSaysNothingAboutTheWorkTunnel`, `aSharedLampBelongsToWhicheverTileRunsNow` |
| `covering.union(claims.map(\.slot))` → `Set(claims.map(\.slot))` | `aLampWhoseLastClaimWentAwayIsPutOut` |
| `covering.union(claims.map(\.slot))` → `covering.union(IndicatorSlot.allCases)` | `onlyTheLampsInPlayAreAnswered` |
| `claims.first {` → `claims.last {` | `whenTwoClaimsRunAtOnceTheFirstHoldsTheLamp` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/VPN/LampBoard.swift Tests/PixelClockKitTests/LampBoardTests.swift
git commit -m "feat: one owner per lamp at a time, resolved before anything is written"
```

---

### Task B10: Refuse a VPN tile that claims a lamp another tile holds at the same moment

**Files:**
- Create: `Sources/PixelClockKit/VPN/LampConflict.swift`
- Create: `Tests/PixelClockKitTests/LampConflictTests.swift`

**Interfaces:**
- Consumes: `PolicyGrid.overlap(with:)` and `.summary` (A10), `IndicatorSlot.lampName` (B4)
- Produces: `LampTile { key, name, slot, policy }`, `LampConflict { existing, saving, slot, overlap; message }` and `LampConflict.check(_:against:) -> LampConflict?`. Production caller: B19's `saveTile`.

**Template:** none in the tree. The spec's refusal text is the acceptance test.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/LampConflictTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private let desk = UUID()
private let kitchen = UUID()

private func tile(
    _ name: String,
    on clock: UUID = desk,
    lamp slot: IndicatorSlot = .middleRight,
    workingIn focuses: Set<MacFocus>,
    _ window: TileWindow = .always,
    paused: Bool = false
) -> LampTile {
    LampTile(
        key: TileKey(clockId: clock, connectorId: "vpn", instance: name.lowercased()),
        name: name,
        slot: slot,
        policy: TilePolicy(
            isPaused: paused,
            refreshSeconds: 60,
            focus: FocusRule(
                silencedIn: Set(MacFocus.allCases).subtracting(focuses).subtracting([.unknown]),
                whenUnknown: .hold
            ),
            window: window
        )
    )
}

private let officeHours = TileWindow.active(HourWindow(startHour: 10, endHour: 19))

@Test func theDesignsOwnExampleIsRefusedInItsOwnWords() throws {
    let pritunl = tile("Pritunl", workingIn: [.work])
    let wireGuard = tile("WireGuard", workingIn: [.work], officeHours)

    let conflict = try #require(LampConflict.check(wireGuard, against: [pritunl]))

    #expect(conflict.message == "Pritunl and WireGuard both claim the middle lamp: Work, 10:00–19:00")
}

@Test func tilesTakingTurnsOnOneLampAreAccepted() {
    let work = tile("Pritunl", workingIn: [.work])
    let personal = tile("Amnezia", workingIn: [.personal])

    #expect(LampConflict.check(personal, against: [work]) == nil)
}

@Test func tilesOnDifferentLampsNeverConflict() {
    let top = tile("Pritunl", lamp: .topRight, workingIn: [.work])
    let bottom = tile("Amnezia", lamp: .bottomRight, workingIn: [.work])

    #expect(LampConflict.check(bottom, against: [top]) == nil)
}

@Test func tilesOnDifferentClocksNeverConflict() {
    let desks = tile("Pritunl", workingIn: [.work])
    let kitchens = tile("Amnezia", on: kitchen, workingIn: [.work])

    #expect(LampConflict.check(kitchens, against: [desks]) == nil)
}

// Saving an edit to a tile hands the check a list that still holds the tile's
// previous self. That is not a second tile.
@Test func aTileDoesNotConflictWithItsOwnEarlierSelf() {
    let before = tile("Pritunl", workingIn: [.work])
    let after = tile("Pritunl", workingIn: [.work, .personal])

    #expect(LampConflict.check(after, against: [before]) == nil)
}

// Unpausing is a save, asked the same question.
@Test func aPausedTileClaimsNothingUntilItIsUnpaused() {
    let pritunl = tile("Pritunl", workingIn: [.work])

    #expect(LampConflict.check(tile("Amnezia", workingIn: [.work], paused: true), against: [pritunl]) == nil)
    #expect(LampConflict.check(tile("Amnezia", workingIn: [.work]), against: [pritunl]) != nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LampConflictTests`
Expected: FAIL. `cannot find 'LampTile' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/PixelClockKit/VPN/LampConflict.swift
import Foundation

/// A VPN tile as the save-time refusal sees it.
public struct LampTile: Equatable, Sendable {
    public let key: TileKey
    /// The VPN's display name.
    public let name: String
    public let slot: IndicatorSlot
    public let policy: TilePolicy

    public init(key: TileKey, name: String, slot: IndicatorSlot, policy: TilePolicy) {
        self.key = key
        self.name = name
        self.slot = slot
        self.policy = policy
    }
}

/// Two VPN tiles on one clock claiming one lamp at the same moment.
public struct LampConflict: Equatable, Sendable {
    /// The tile already saved.
    public let existing: String
    /// The tile being saved, which is refused.
    public let saving: String
    public let slot: IndicatorSlot
    public let overlap: PolicyGrid

    /// `Pritunl and WireGuard both claim the middle lamp: Work, 10:00–19:00`.
    public var message: String {
        "\(existing) and \(saving) both claim the \(slot.lampName) lamp: \(overlap.summary)"
    }

    /// The first tile on the same clock and the same lamp whose grid meets
    /// this one's, or nil when the save may go ahead.
    ///
    /// Exact, because the grids are the whole of both policies: tiles taking
    /// turns — one in Work, one in Personal, or one before 13:00 and one after
    /// — share a lamp; tiles that would both light it at any moment do not.
    /// A paused tile claims nothing, and unpausing it is a save that is asked
    /// the same question.
    public static func check(_ saving: LampTile, against others: [LampTile]) -> LampConflict? {
        for other in others
        where other.key != saving.key
            && other.key.clockId == saving.key.clockId
            && other.slot == saving.slot {
            let overlap = saving.policy.grid.overlap(with: other.policy.grid)
            if !overlap.isEmpty {
                return LampConflict(
                    existing: other.name, saving: saving.name, slot: saving.slot, overlap: overlap
                )
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LampConflictTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| drop `other.key != saving.key &&` | `aTileDoesNotConflictWithItsOwnEarlierSelf` |
| drop `&& other.key.clockId == saving.key.clockId` | `tilesOnDifferentClocksNeverConflict` |
| drop `&& other.slot == saving.slot` | `tilesOnDifferentLampsNeverConflict` |
| swap `existing:` and `saving:` in the constructor | `theDesignsOwnExampleIsRefusedInItsOwnWords` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/VPN/LampConflict.swift Tests/PixelClockKitTests/LampConflictTests.swift
git commit -m "feat: refuse a VPN tile that claims a lamp another holds at the same moment"
```

---

### Task B11: Which connectors a clock may take, and why not

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TileCatalogue.swift`
- Create: `Tests/PixelClockKitTests/TileCatalogueTests.swift`

**Interfaces:**
- Consumes: `ClockRecord`, `TileRecord` (Phase 1); `Connector.ulanziFace` (**Phase 3b**); `VPNConnector` (B8)
- Produces: `Instancing { single, perKey }`; `TileCandidate { connectorId, models, instancing, isAudible }` with `init(_ connector: some Connector)` and `init(_ vpn: VPNConnector)`; `TileAvailability { available, unavailable(String), notListed }`; `TileCatalogue.availability(of:on:tiles:clocks:)`. Production caller: B19's `AppModel.availability(of:on:)`.

**Why a candidate and not the connector.** `Connector` has an associated type, so `any Connector` cannot hand out its faces. The candidate is read off a connector through an opened existential, once, and every rule then works on plain values. It also lets the VPN, which is not a `Connector`, sit in the same menu.

**Template:** none in the tree. The spec's § Adding a tile rules 1–3 are the acceptance test. Rule 4 is B10's.

- [ ] **Step 1: Write the failing test.** The two private connector doubles at the bottom use Phase 2's `AwtrixFace { _ in AwtrixDelivery(text: "") }` and Phase 3b's `UlanziFace`. Re-verify both initialisers, and if Phase 3b's `UlanziFace` takes something other than a closure, build it the way Phase 3b's own tests do.

```swift
// Tests/PixelClockKitTests/TileCatalogueTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.2")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.3")
private let clocks = [desk, kitchen]

private let weather = TileCandidate(
    connectorId: "weather", models: [.awtrix3, .ulanziTC002], instancing: .single, isAudible: false
)
private let anecdotes = TileCandidate(
    connectorId: "anecdotes", models: [.awtrix3], instancing: .single, isAudible: true
)
private let vpn = TileCandidate(
    connectorId: "vpn", models: [.awtrix3], instancing: .perKey, isAudible: false
)

private func placed(_ connectorId: String, on clock: ClockRecord, instance: String = "") -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connectorId, instance: instance),
        policy: TilePolicyRecord(TileDefaults.weather)
    )
}

private func availability(
    _ candidate: TileCandidate, on clock: ClockRecord, _ tiles: [TileRecord] = []
) -> TileAvailability {
    TileCatalogue.availability(of: candidate, on: clock, tiles: tiles, clocks: clocks)
}

@Test func aConnectorWithNoFaceForTheModelSaysSo() {
    #expect(availability(anecdotes, on: desk) == .unavailable("not supported on TC002"))
    #expect(availability(vpn, on: desk) == .unavailable("not supported on TC002"))
}

@Test func aConnectorWithAFaceForTheModelIsAvailable() {
    #expect(availability(weather, on: desk) == .available)
    #expect(availability(anecdotes, on: kitchen) == .available)
}

@Test func aSingleConnectorAlreadyOnThisClockIsNotListed() {
    #expect(availability(weather, on: kitchen, [placed("weather", on: kitchen)]) == .notListed)
}

@Test func aSilentConnectorOnAnotherClockIsStillAvailableHere() {
    #expect(availability(weather, on: desk, [placed("weather", on: kitchen)]) == .available)
}

@Test func anAudibleConnectorOnAnotherClockNamesTheClockItSpeaksThrough() {
    let elsewhere = ClockRecord(name: "Study", model: .awtrix3, address: "10.0.0.4")
    let tiles = [placed("anecdotes", on: elsewhere)]

    #expect(
        TileCatalogue.availability(
            of: anecdotes, on: kitchen, tiles: tiles, clocks: clocks + [elsewhere]
        ) == .unavailable("already speaking through Study")
    )
}

// Asked of the tiles as they are, not stamped when one was made: take the
// anecdotes off the study and the kitchen may have them.
@Test func theAnswerFollowsTheTilesAsTheyAreNow() {
    let elsewhere = ClockRecord(name: "Study", model: .awtrix3, address: "10.0.0.4")

    #expect(
        TileCatalogue.availability(
            of: anecdotes, on: kitchen, tiles: [], clocks: clocks + [elsewhere]
        ) == .available
    )
}

@Test func aPerKeyConnectorIsListedWhateverIsAlreadyOnTheClock() {
    #expect(availability(vpn, on: kitchen, [placed("vpn", on: kitchen, instance: "pritunl")]) == .available)
}

@Test func theFaceIsAskedBeforeAnythingPlacedAnywhere() {
    let tiles = [placed("anecdotes", on: desk), placed("anecdotes", on: kitchen)]

    #expect(availability(anecdotes, on: desk, tiles) == .unavailable("not supported on TC002"))
}

// The VPN is a lamp, not a scene: an AWTRIX clock only, one tile per VPN.
@Test func theVPNIsOfferedOnAWTRIXClocksOnePerVPN() {
    #expect(TileCandidate(VPNConnector(isUp: { _ in true })) == TileCandidate(
        connectorId: "vpn", models: [.awtrix3], instancing: .perKey, isAudible: false
    ))
}

// A scene connector supports the models it has faces for, and nothing says so
// but the faces.
@Test func aSceneConnectorIsOfferedWhereItHasAFace() {
    #expect(TileCandidate(AWTRIXOnly()).models == [.awtrix3])
    #expect(TileCandidate(BothModels()).models == [.awtrix3, .ulanziTC002])
}

private struct AWTRIXOnly: Connector {
    let id = "awtrix-only"
    let displayName = "AWTRIX only"
    let defaultInterval: TimeInterval = 600
    let isAudible = true
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
}

private struct BothModels: Connector {
    let id = "both"
    let displayName = "Both models"
    let defaultInterval: TimeInterval = 600
    let isAudible = false
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
    var ulanziFace: UlanziFace<Int>? { UlanziFace { _ in "" } }
}

// Rule 3 is about ANOTHER clock. No shipped connector is audible and keyed at
// once, so this is posed with a candidate made for it: a second instance on the
// same clock speaks through the same room, and naming this very clock as the
// one "already speaking" would be the rule refusing a tile for its own sibling.
@Test func anAudibleTileOnThisClockIsNotAnotherClock() {
    let radio = TileCandidate(
        connectorId: "radio", models: [.awtrix3], instancing: .perKey, isAudible: true
    )

    #expect(availability(radio, on: kitchen, [placed("radio", on: kitchen, instance: "bbc")]) == .available)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TileCatalogueTests`
Expected: FAIL. `cannot find 'TileCandidate' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/PixelClockKit/Tiles/TileCatalogue.swift
import Foundation

/// How many tiles of one connector a clock may carry.
public enum Instancing: Sendable, Equatable {
    /// One. Every scene connector is this.
    case single
    /// One per key — the VPN tile, one per watched VPN.
    case perKey
}

/// A connector as the Add tile menu needs to see it: no reading, no faces,
/// just what decides whether it may go on a clock.
public struct TileCandidate: Equatable, Sendable {
    public let connectorId: String
    /// The models it has a face for — which is the only thing that says what
    /// it supports, so the two cannot disagree.
    public let models: Set<ClockModel>
    public let instancing: Instancing
    public let isAudible: Bool

    public init(
        connectorId: String, models: Set<ClockModel>, instancing: Instancing, isAudible: Bool
    ) {
        self.connectorId = connectorId
        self.models = models
        self.instancing = instancing
        self.isAudible = isAudible
    }

    /// A scene connector. Every one has an AWTRIX face, and a TC002 face only
    /// if it drew one.
    public init(_ connector: some Connector) {
        var models: Set<ClockModel> = [.awtrix3]
        if connector.ulanziFace != nil { models.insert(.ulanziTC002) }
        self.init(
            connectorId: connector.id,
            models: models,
            instancing: .single,
            isAudible: connector.isAudible
        )
    }

    /// The VPN tile: a lamp on an AWTRIX clock, one per watched VPN, silent.
    public init(_ vpn: VPNConnector) {
        self.init(
            connectorId: vpn.id, models: [.awtrix3], instancing: .perKey, isAudible: false
        )
    }
}

public enum TileAvailability: Equatable, Sendable {
    case available
    /// Listed, disabled, with the reason beside it.
    case unavailable(String)
    /// Not listed at all — a single tile of it is already on this clock.
    case notListed
}

/// Which connectors the Add tile menu offers for a clock, and why not.
public enum TileCatalogue {
    /// Asked of the tiles as they are now, never stamped when a tile was made,
    /// so a tile removed from the kitchen frees its connector for the desk.
    ///
    /// The rules in the design's order. The face comes first because it is
    /// about the connector and the model and nothing placed anywhere: an
    /// unsupported connector says so whatever else is true.
    public static func availability(
        of candidate: TileCandidate,
        on clock: ClockRecord,
        tiles: [TileRecord],
        clocks: [ClockRecord]
    ) -> TileAvailability {
        guard candidate.models.contains(clock.model) else {
            return .unavailable("not supported on \(modelName(clock.model))")
        }
        let placed = tiles.filter { $0.key.connectorId == candidate.connectorId }
        if candidate.instancing == .single, placed.contains(where: { $0.key.clockId == clock.id }) {
            return .notListed
        }
        // Every audible connector plays through the Mac's speakers today, so
        // one on any other clock is already the voice in this room. A clock
        // that gains a speaker of its own (follow-up F1) changes this rule to
        // "whose sound plays through the Mac", not the rule's place here.
        if candidate.isAudible,
            let elsewhere = placed.first(where: { $0.key.clockId != clock.id }) {
            let name = clocks.first { $0.id == elsewhere.key.clockId }?.name ?? "another clock"
            return .unavailable("already speaking through \(name)")
        }
        return .available
    }

    private static func modelName(_ model: ClockModel) -> String {
        switch model {
        case .awtrix3: "AWTRIX 3"
        case .ulanziTC002: "TC002"
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TileCatalogueTests`
Expected: PASS, 12 tests.

- [ ] **Step 5: Mutate, one site at a time** (the face guard sits in front of rules 2 and 3, so run its row last and re-run the two rows before it)

| Mutation | Must fail |
| --- | --- |
| `if candidate.instancing == .single, placed…` → `if placed…` | `aPerKeyConnectorIsListedWhateverIsAlreadyOnTheClock` |
| `placed.first(where: { $0.key.clockId != clock.id })` → `placed.first` | `anAudibleTileOnThisClockIsNotAnotherClock` |
| `if candidate.isAudible,` → `if true,` | `aSilentConnectorOnAnotherClockIsStillAvailableHere` |
| `if connector.ulanziFace != nil { models.insert(.ulanziTC002) }` → `models.insert(.ulanziTC002)` | `aSceneConnectorIsOfferedWhereItHasAFace` |
| delete the `guard candidate.models.contains(clock.model)` block | `aConnectorWithNoFaceForTheModelSaysSo`, `theFaceIsAskedBeforeAnythingPlacedAnywhere` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles/TileCatalogue.swift Tests/PixelClockKitTests/TileCatalogueTests.swift
git commit -m "feat: which connectors a clock may take, and why not"
```

---

### Task B12: Notice when a tile's policy changes its answer

**Files:**
- Create: `Sources/PixelClockKit/Scheduling/TileVerdicts.swift`
- Create: `Tests/PixelClockKitTests/TileVerdictsTests.swift`

**Interfaces:**
- Consumes: `TileKey`
- Produces: `public struct TileVerdicts` with `mutating func update(_ current: [TileKey: Bool]) -> (arrived: Set<TileKey>, left: Set<TileKey>)`. Production caller: B17.

**Template:** `AppModel.reactToAFocusChange()` with `lastSeenFocus`: the first reading is not a switch, and only a change is news. `FocusChangeTests` pins that through the app, and this pins it on the value.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/TileVerdictsTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private let claude = TileKey(clockId: UUID(), connectorId: "claude")
private let weather = TileKey(clockId: UUID(), connectorId: "weather")

@Test func theFirstLookIsNotAChange() {
    var verdicts = TileVerdicts()

    let change = verdicts.update([claude: false, weather: true])

    #expect(change.arrived.isEmpty)
    #expect(change.left.isEmpty)
}

@Test func aTileItsPolicyStopsAllowingHasLeft() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true])

    let change = verdicts.update([claude: false])

    #expect(change.left == [claude])
    #expect(change.arrived.isEmpty)
}

@Test func aTileItsPolicyStartsAllowingHasArrived() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: false])

    let change = verdicts.update([claude: true])

    #expect(change.arrived == [claude])
    #expect(change.left.isEmpty)
}

@Test func anAnswerThatStaysTheSameIsNotNews() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true, weather: false])

    for _ in 0..<3 {
        let change = verdicts.update([claude: true, weather: false])
        #expect(change.arrived.isEmpty && change.left.isEmpty)
    }
}

@Test func aTileAddedLaterIsNotAChangeOnItsFirstLook() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true])

    let change = verdicts.update([claude: true, weather: false])

    #expect(change.left.isEmpty)
}

@Test func aTileRemovedAndAddedAgainStartsFresh() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true])
    _ = verdicts.update([:])

    let change = verdicts.update([claude: false])

    #expect(change.left.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TileVerdictsTests`
Expected: FAIL. `cannot find 'TileVerdicts' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/PixelClockKit/Scheduling/TileVerdicts.swift
import Foundation

/// Which tiles' policies changed their answer since the last look.
///
/// What a Focus switch or an hour boundary acts on. Only a CHANGE is news:
/// asking every minute and acting on the answer would re-push an unchanged app
/// sixty times an hour and re-retract one already gone.
public struct TileVerdicts: Sendable {
    private var last: [TileKey: Bool] = [:]

    public init() {}

    /// Records whether each tile's policy lets it run now, and returns the
    /// tiles that started and stopped being allowed since the last call.
    ///
    /// A tile seen for the first time is not a change — a launch, or a tile
    /// just added, already delivers what it owes by its own route, and counting
    /// its first look would push it twice or retract what was just delivered.
    /// A tile missing from `current` is forgotten, so one removed and added
    /// again starts fresh.
    public mutating func update(
        _ current: [TileKey: Bool]
    ) -> (arrived: Set<TileKey>, left: Set<TileKey>) {
        defer { last = current }
        var arrived: Set<TileKey> = []
        var left: Set<TileKey> = []
        for (key, runs) in current {
            guard let before = last[key], before != runs else { continue }
            if runs {
                arrived.insert(key)
            } else {
                left.insert(key)
            }
        }
        return (arrived, left)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TileVerdictsTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `guard let before = last[key], before != runs` → `guard last[key] != runs` (a first look counts) | `theFirstLookIsNotAChange` |
| `defer { last = current }` → `defer { last.merge(current) { $1 } }` (nothing forgotten) | `aTileRemovedAndAddedAgainStartsFresh` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Scheduling/TileVerdicts.swift Tests/PixelClockKitTests/TileVerdictsTests.swift
git commit -m "feat: notice when a tile's policy changes its answer"
```

---

### Task B13: A session per clock, and a schedule keyed by tile

The structural task. Behaviour for one clock does not change, and the whole existing suite is the proof of that. What becomes true: every clock in `clocks` has its own session, built on its own device with its own chain and custody. Every schedule, hold, outcome and pending run is keyed by `TileKey`, and a tile runs through its own clock's session. The policy semantics (Focus, hours) do not move until B16, so this task changes structure only.

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (state, `init`, `live()`, `teardown()`, `replay`, the scheduling methods)
- Modify: `Tests/PixelClockTilesAppTests/Doubles.swift` (`testModel` gains `clocks:`, `tiles:`, `sessions:`; `SpyHost` gains `parkInRestore:`)
- Create: `Tests/PixelClockTilesAppTests/SessionsPerClockTests.swift`

**Interfaces:**
- Consumes: `ClockStore`, `TileStore`, `TileSettingsStore(defaults:clockId:)` (Phase 1); `AwtrixClockSession` (Phase 2) and the TC002 session (**Phase 3**); `StoredLocation(defaults:clockId:)` (B7); `RefreshScale.snapped` (A3)
- Produces, on `AppModel`: `@Published private(set) var clocks: [ClockRecord]`; `@Published var selectedClockId: UUID?` (key `selectedClockId`, read at launch, first clock when unset); `func reloadClocks()`; `runNow(_ key: TileKey)`; the panel's `nextRun`, `lastResults` and `lastMaintenanceFailure` as `[String: …]` **projections of the selected clock**, so `MenuPanel` is untouched until Phase 5. The `init` takes `clocks: [ClockRecord]`, `tiles: TileStore` and `makeSession: @MainActor (ClockRecord) -> any ConnectorRunning` in place of Phase 1's `clock:` and Phase 2's `host:`.

**Template:** Phase 1 T3, which already moved `AppModel` from a host string to a `ClockRecord`. This does the same move from one record to a list.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PixelClockTilesAppTests/SessionsPerClockTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Two clocks, two sessions, and a tile only ever reaches the clock it is on.
// A clock that stops answering holds up only its own tiles; a quit gives every
// clock back at once, inside the budget one clock had.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")

private func tile(_ connector: String, on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connector),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )
}

@Test @MainActor func eachTileRunsThroughTheSessionOfItsOwnClock() async {
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "weather"), StubConnector(id: "claude")],
        clocks: [desk, kitchen],
        tiles: [tile("weather", on: desk), tile("claude", on: kitchen)],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.runNow(TileKey(clockId: desk.id, connectorId: "weather"))
    subject.runNow(TileKey(clockId: kitchen.id, connectorId: "claude"))

    #expect(await waitUntil { onDesk.calls.contains("run:weather") && inKitchen.calls.contains("run:claude") })
    #expect(onDesk.calls.contains("run:claude") == false)
    #expect(inKitchen.calls.contains("run:weather") == false)
}

// The same connector on two clocks is two tiles with two schedules, and each
// asks its own session how long to wait — a backoff on one is not the other's.
@Test @MainActor func theSameConnectorOnTwoClocksIsTwoSchedules() async {
    let schedule = Metronome()
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "weather")],
        sleep: schedule.sleep,
        clocks: [desk, kitchen],
        tiles: [tile("weather", on: desk), tile("weather", on: kitchen)],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.start()

    #expect(await waitUntil { schedule.parked == 2 })
    #expect(onDesk.delayQueries == 1)
    #expect(inKitchen.delayQueries == 1)
    await subject.teardown()
}

// Both restores are entered before either is let go: a second clock does not
// double what a quit may take.
@Test @MainActor func quittingGivesEveryClockBackAtOnce() async {
    let gate = Gate()
    let onDesk = SpyHost(parkInRestore: gate)
    let inKitchen = SpyHost(parkInRestore: gate)
    let subject = testModel(clocks: [desk, kitchen], tiles: [], sessions: [desk.id: onDesk, kitchen.id: inKitchen])

    let quit = Task { await subject.teardown() }

    #expect(await waitUntil { gate.enteredCount == 2 })
    gate.open()
    await quit.value
    #expect(onDesk.calls.contains("restore:all"))
    #expect(inKitchen.calls.contains("restore:all"))
}

@Test @MainActor func aClockTakenOutOfTheListIsGivenBackAndItsTilesStop() async throws {
    let schedule = Metronome()
    let inKitchen = SpyHost()
    let defaults = try #require(UserDefaults(suiteName: "sessions-\(UUID().uuidString)"))
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        defaults: defaults,
        sleep: schedule.sleep,
        clocks: [desk, kitchen],
        tiles: [tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: inKitchen]
    )
    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })

    try ClockStore(defaults: defaults).replaceAll([desk])
    subject.reloadClocks()

    #expect(await waitUntil { inKitchen.calls.contains("restore:all") })
    #expect(subject.clocks == [desk])
    schedule.tick()
    #expect(await waitUntil({ inKitchen.calls.contains("run:claude") }, limit: 0.1) == false)
    await subject.teardown()
}

@Test @MainActor func aClockAddedToTheListGetsASessionAndItsTilesRun() async throws {
    let defaults = try #require(UserDefaults(suiteName: "sessions-\(UUID().uuidString)"))
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        defaults: defaults,
        clocks: [desk],
        tiles: [],
        sessions: [kitchen.id: inKitchen]
    )

    try ClockStore(defaults: defaults).replaceAll([desk, kitchen])
    try TileStore(defaults: defaults).replaceAll([tile("claude", on: kitchen)])
    subject.reloadClocks()
    subject.runNow(TileKey(clockId: kitchen.id, connectorId: "claude"))

    #expect(await waitUntil { inKitchen.calls.contains("run:claude") })
}

// The History is the anecdote tile's, and Play again goes to its clock.
@Test @MainActor func playAgainGoesThroughTheClockTheAnecdoteTileIsOn() async throws {
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let anecdote = try playableAnecdote(id: "a1", text: "joke")
    let subject = testModel(
        connectors: [StubConnector(id: "anecdotes")],
        anecdotes: StubAnecdotes(id: "anecdotes"),
        clocks: [desk, kitchen],
        tiles: [tile("anecdotes", on: kitchen)],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.replay(anecdote)

    #expect(await waitUntil { inKitchen.calls.contains { $0.hasPrefix("deliver:") } })
    #expect(onDesk.calls.contains { $0.hasPrefix("deliver:") } == false)
}

// Until Phase 5 draws tiles, the panel reads rows by connector — the selected
// clock's.
@Test @MainActor func thePanelShowsTheSelectedClocksTiles() async {
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        clocks: [desk, kitchen],
        tiles: [tile("claude", on: desk), tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )

    subject.selectedClockId = kitchen.id
    subject.runNow(TileKey(clockId: kitchen.id, connectorId: "claude"))

    #expect(await waitUntil { subject.lastResults["claude"] != nil })
    subject.selectedClockId = desk.id
    #expect(subject.lastResults["claude"] == nil)
}
```

`StubConnector(id:isAudible:)`, `StubAnecdotes(id:)`, `playableAnecdote(id:text:)`, `Gate`, `Metronome` and `waitUntil` exist in `Doubles.swift` today. Swift takes labelled arguments in declaration order, defaulted ones included, so every `testModel` call in this plan orders its arguments the way the signature declares them: the existing parameters first, then `clocks:`, `tiles:` and `sessions:` last.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SessionsPerClockTests`
Expected: FAIL. `extra arguments 'clocks', 'tiles', 'sessions' in call`.

- [ ] **Step 3: Give `AppModel` its clocks and sessions.** Replace Phase 1's `clock`/`clocks` pair and Phase 2's `host` with:

```swift
    /// Which clock the panel shows and the glyph is about. Phase 5's switcher
    /// writes it; until then it is the first clock unless something set it.
    static let selectedClockKey = "selectedClockId"

    /// Every clock this app drives, as the settings list them.
    @Published private(set) var clocks: [ClockRecord]
    @Published var selectedClockId: UUID? {
        didSet { defaults.set(selectedClockId?.uuidString, forKey: Self.selectedClockKey) }
    }
    /// One session per clock, each with its own delivery chain and custody —
    /// so a clock that stops answering holds up only its own tiles.
    private var sessions: [UUID: any ConnectorRunning] = [:]
    private let makeSession: @MainActor (ClockRecord) -> any ConnectorRunning
    private let tiles: TileStore

    private func session(for key: TileKey) -> (any ConnectorRunning)? { sessions[key.clockId] }

    /// The selected clock's tile of this connector, which is what the panel's
    /// rows are about until Phase 5 draws tiles.
    private func selectedKey(_ connectorId: String) -> TileKey? {
        selectedClockId.map { TileKey(clockId: $0, connectorId: connectorId) }
    }
```

`init` sets `clocks`, `tiles` and `makeSession` from its new parameters. It sets `selectedClockId` from `defaults.string(forKey: Self.selectedClockKey).flatMap(UUID.init(uuidString:))`, falling back to `clocks.first?.id` when that is nil or names no clock. Then it builds `sessions[clock.id] = makeSession(clock)` for each clock. Everything that read `clock` now reads `clocks.first { $0.id == key.clockId }` for a key, or the selected clock for the panel.

- [ ] **Step 4: Key the schedule by tile.** Mechanical, one stored property at a time, building after each:

| Was | Becomes |
| --- | --- |
| `timers: [String: Task<Void, Never>]` | `[TileKey: Task<Void, Never>]` |
| `@Published nextRun: [String: NextRun]` | `@Published private(set) var tileNextRun: [TileKey: NextRun]`, plus `var nextRun: [String: NextRun] { projected(tileNextRun) }` |
| `lastResults`, `lastMaintenanceFailure` | `tileLastResults`, `tileLastMaintenanceFailure` by `TileKey`, plus the same projection |
| `outstanding: [String: Int]`, `scheduledDue: [String: Date]` | by `TileKey` |
| `heldRuns: Set<String>`, `launchDeliveriesOwed: Set<String>` | `Set<TileKey>` |
| `reschedule(_ connector:, resuming:)`, `tick(_ id:)`, `runAndReport`, `restock`, `markUnderWay`, `reportOutcome`, `record`, `noteDelivery`, `noteNextRun`, `publishNextRun`, `whatIsLeftOf`, `scheduleHold(for:)`, `retract` | take `_ key: TileKey`; `isAudible(key.connectorId)` |
| `host.runOnce(connectorId: id)` / `.maintain` / `.nextDelay` | `session(for: key)?.runOnce(connectorId: key.connectorId) ?? .failed("no clock \(key.clockId)")`, and likewise |
| the interval, `settings(for:).interval` | `RefreshScale.snapped(TimeInterval(tile.policy.refreshSeconds))`, read from `tiles.all()` |
| `runNow(_ id: String)` | `runNow(_ key: TileKey)`, plus the panel's `func runNow(_ id: String) { if let key = selectedKey(id) { runNow(key) } }` |
| `settings(for:)`, `setEnabled(_:for:)`, `setIntervalPosition(_:for:)` | read and `TileStore.update` the selected clock's tile (`isPaused = !enabled`; `refreshSeconds = Int(IntervalScale.duration(atPosition:))` — the old slider's scale until Phase 5) |

```swift
    /// A by-tile map, seen the way the panel still reads it: the selected
    /// clock's single tiles, by connector.
    private func projected<Value>(_ byTile: [TileKey: Value]) -> [String: Value] {
        var byConnector: [String: Value] = [:]
        for (key, value) in byTile where key.clockId == selectedClockId && key.instance.isEmpty {
            byConnector[key.connectorId] = value
        }
        return byConnector
    }
```

`start()` reschedules every stored tile whose clock has a session, where it used to go over `registry.all`. A tile whose connector the registry does not know gets no timer. VPN tiles are skipped here: B18 gives them their own path.

- [ ] **Step 5: `reloadClocks`, the quit, and Play again**

```swift
    /// Brings the sessions in line with the clocks as stored.
    ///
    /// A clock gone from the list has its schedules stopped and everything it
    /// was lent given back through its own custody, then its session dropped.
    /// A clock new to the list gets a session and its tiles' schedules. Called
    /// by the Clocks settings (Phase 5) after every change they make.
    func reloadClocks() {
        let stored = ClockStore(defaults: defaults).all()
        let kept = Set(stored.map(\.id))
        for (id, session) in sessions where !kept.contains(id) {
            for key in timers.keys where key.clockId == id {
                timers.removeValue(forKey: key)?.cancel()
            }
            let restore = nextRestoreKey
            nextRestoreKey += 1
            restores[restore] = Task { [weak self] in
                await session.restoreDeviceState(borrowedBy: nil)
                self?.restores[restore] = nil
            }
            sessions[id] = nil
        }
        for clock in stored where sessions[clock.id] == nil {
            sessions[clock.id] = makeSession(clock)
        }
        clocks = stored
        if selectedClockId.map(kept.contains) != true { selectedClockId = stored.first?.id }
        for tile in tiles.all() where timers[tile.key] == nil && sessions[tile.key.clockId] != nil {
            reschedule(tile.key)
        }
    }
```

In `teardown()`, replace `await host.restoreDeviceState(borrowedBy: nil)` with:

```swift
        // Every clock at once, inside the budget one clock had: a second clock
        // does not double what a quit may take.
        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values {
                group.addTask { await session.restoreDeviceState(borrowedBy: nil) }
            }
        }
```

`replay(_:)` delivers through the session of the clock carrying the anecdote tile:

```swift
    private var anecdoteSession: (any ConnectorRunning)? {
        guard let anecdotes else { return nil }
        return tiles.all().first { $0.key.connectorId == anecdotes.id }
            .flatMap { sessions[$0.key.clockId] }
    }
```

With no anecdote tile anywhere, `replayResult` says `"No clock carries the anecdotes"` and nothing is sent.

- [ ] **Step 6: `live()` builds a session per clock.** Hoist what every clock shares above `return AppModel(`: the anecdote wiring, the Claude connector, one `OpenMeteoSource`, the audio player and `defaults`. Then:

```swift
        let weather = OpenMeteoSource(transport: transport)
        let makeSession: @MainActor (ClockRecord) -> any ConnectorRunning = { clock in
            // A registry per clock, so each clock's weather reads its own tile's
            // place through the one shared source — which caches per place.
            let registry = ConnectorRegistry()
            registry.register(anecdotes.connector)
            let place = StoredLocation(defaults: defaults, clockId: clock.id)
            registry.register(WeatherConnector(source: weather, location: { place.current }))
            registry.register(claude)
            let store = TileSettingsStore(defaults: defaults, clockId: clock.id)
            // Phase 3's branch on the model goes here unchanged: AWTRIX builds
            // an `AwtrixClockSession` on its own `AwtrixDevice(host: clock.address, …)`,
            // the TC002 its own session. Only `registry` and `store` are per clock now.
            let device = AwtrixDevice(host: clock.address, transport: transport)
            return AwtrixClockSession(
                device: device,
                registry: registry,
                store: store,
                audio: audio,
                iconInstaller: CatalogueIconInstaller(
                    device: device,
                    transport: transport,
                    // One record for the installation, as today. Which clock
                    // an upload went to is not recorded yet (B21 owes it).
                    uploads: UserDefaultsUploadedIconStore(defaults: defaults)
                ),
                borrowedOverlays: UserDefaultsBorrowedOverlayStore(defaults: defaults)
            )
        }
```

`AppModel`'s own `registry` (the panel's rows, `isAudible`, the History) stays the one registry `live()` builds today. The per-clock registries hold the same connector instances, except each clock's weather connector. `borrowedOverlays` is still the one key here, and it becomes per clock in B15.

- [ ] **Step 7: Doubles.** `testModel` gains, after its last existing parameter (`relocate:`):

```swift
    // One AWTRIX clock, so every test written before there were several keeps
    // driving exactly one.
    clocks: [ClockRecord] = [ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")],
    // Nil: one tile per connector on the first clock, from the connector's own
    // default policy — the installation the migration leaves.
    tiles: [TileRecord]? = nil,
    // Nil: `host` for the first clock and a fresh `SpyHost` for any other.
    sessions: [UUID: any ConnectorRunning]? = nil
```

It writes `clocks` and `tiles` into its `defaults` through `ClockStore` and `TileStore`, and passes `makeSession: { clock in sessions?[clock.id] ?? (clock.id == clocks.first?.id ? host : SpyHost()) }`. `SpyHost` gains `parkInRestore: Gate? = nil`, entered inside `restoreDeviceState` after the call is recorded. That adapts a double to a new question. No test's arrange or assert changes.

- [ ] **Step 8: Run to verify it passes**

Run: `swift test --filter SessionsPerClockTests`
Expected: PASS, 7 tests.

Run: `swift test`
Expected: PASS with the same count as before this task plus 7. Every test written before this task drives one clock through `host`, and it is unchanged.

- [ ] **Step 9: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `session(for:)` answers `sessions.values.first` | `eachTileRunsThroughTheSessionOfItsOwnClock` |
| the quit awaits each session in turn (`for session in sessions.values { await … }`) | `quittingGivesEveryClockBackAtOnce` |
| `reloadClocks` drops a gone clock's session without the restore | `aClockTakenOutOfTheListIsGivenBackAndItsTilesStop` |
| `reloadClocks` leaves the timers of a gone clock running | the same test (`run:claude` after the tick) |
| `anecdoteSession` answers the first session | `playAgainGoesThroughTheClockTheAnecdoteTileIsOn` |
| `projected` ignores `selectedClockId` | `thePanelShowsTheSelectedClocksTiles` |

- [ ] **Step 10: Commit**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/Doubles.swift Tests/PixelClockTilesAppTests/SessionsPerClockTests.swift
git commit -m "feat: a session per clock, and a schedule keyed by tile"
```

---

### Task B14: Health per clock, battery warnings that name it — and `batteryHistory` migrates

**Files:**
- Modify: `Sources/PixelClockKit/Device/BatteryHistoryStore.swift` (keyed by hardware identity)
- Create: `Sources/PixelClockTilesApp/BatteryHistoryMigration.swift`, `Sources/PixelClockTilesApp/ClockHealth.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`poll()`, `followTheClock()`, `isDeviceOnline`, `live()`), `Sources/PixelClockTilesApp/BatteryAlert.swift` (`BatteryWarningPresenting.warn(_:on:)`, `BatteryAlertWords.body(for:on:)`)
- Create: `Tests/PixelClockKitTests/KeyedBatteryHistoryTests.swift`, `Tests/PixelClockTilesAppTests/BatteryHistoryMigrationTests.swift`, `Tests/PixelClockTilesAppTests/HealthPerClockTests.swift`
- Modify (arrange only): `Tests/PixelClockKitTests/BatteryTrajectoryTests.swift` (3 constructor calls gain `hardwareIdentity:`), `Tests/PixelClockTilesAppTests/Doubles.swift` (`SpyAlerts` records the clock name), `Tests/PixelClockTilesAppTests/BatteryAlertTests.swift`

**Interfaces:**
- Consumes: `DeviceMonitor`, `BatteryWarning`, `RelocationSchedule` (existing); the TC002 health (**Phase 3**)
- Produces: `UserDefaultsBatteryHistoryStore(defaults:hardwareIdentity: String?)` and `static func key(forHardwareIdentity:)`. It reads under the clock's known name and saves under the name the series carries (`BatteryHistory.uid`). Also `BatteryHistoryMigration` (marker `migration.batteryHistory`); `@MainActor final class ClockHealth` per clock (monitor, unanswered-poll count, relocation); `BatteryAlertWords.body(for:on:)` → `"Desk: 20% left. Plug it in soon."`.

**Template:** the health that is in `AppModel` today (Phase 2 D9). `ClockHealth` is its `monitor`, `unansweredPolls` and `followTheClock()` moved as they are, with one instance per clock.

- [ ] **Step 1: Write the failing tests.** The keyed store:

```swift
// Tests/PixelClockKitTests/KeyedBatteryHistoryTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "keyed-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

private func series(_ uid: String, uptime: Int) -> BatteryHistory {
    BatteryHistory(uid: uid, uptime: uptime, samples: [])
}

@Test func eachClocksBatterySeriesIsKeptUnderItsOwnName() throws {
    try withDefaults { defaults in
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").save(series("desk", uptime: 1))
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "kitchen").save(series("kitchen", uptime: 2))

        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").storedHistory() == series("desk", uptime: 1))
        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "kitchen").storedHistory() == series("kitchen", uptime: 2))
    }
}

// A clock that has never answered has no name yet, and so nothing to resume.
@Test func aClockThatHasNeverAnsweredStartsCold() throws {
    try withDefaults { defaults in
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").save(series("desk", uptime: 1))

        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: nil).storedHistory() == nil)
    }
}

// Its first answer names it. The series from that poll goes where the next
// launch — which knows the name from the clock record — will look.
@Test func aSeriesIsSavedUnderTheClockItCameOff() throws {
    try withDefaults { defaults in
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: nil).save(series("desk", uptime: 1))

        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").storedHistory() == series("desk", uptime: 1))
    }
}
```

`BatteryHistory(uid:uptime:samples:)` with `samples: []` is the real initialiser, and an empty series is a valid one.

The migration step:

```swift
// Tests/PixelClockTilesAppTests/BatteryHistoryMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let series = Data(#"{"uid":"awtrix_a07f9c","uptime":9000,"samples":[]}"#.utf8)

@Test func theSeriesMovesUnderTheNameOfItsClockByteForByte() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: "batteryHistory.awtrix_a07f9c") == series)
    }
}

@Test func aSeriesThatNamesNoClockIsLeftWhereItIs() throws {
    try withFreshDefaults { defaults in
        defaults.set(Data("not a series".utf8), forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("batteryHistory.") } == false)
        #expect(defaults.bool(forKey: BatteryHistoryMigration.markerKey))
    }
}

@Test func theBatteryHistoryMigrationLeavesTheOldKeyAsItWas() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: BatteryHistoryMigration.legacyKey) == series)
    }
}

@Test func theBatteryHistoryMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.writes.last == BatteryHistoryMigration.markerKey)
    }
}

// The per-clock series has moved on since; the old one must not come back
// over it.
@Test func aSecondBatteryHistoryMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)
        BatteryHistoryMigration(defaults: defaults).run()
        let newer = Data(#"{"uid":"awtrix_a07f9c","uptime":9600,"samples":[]}"#.utf8)
        defaults.set(newer, forKey: "batteryHistory.awtrix_a07f9c")

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: "batteryHistory.awtrix_a07f9c") == newer)
    }
}
```

The wiring:

```swift
// Tests/PixelClockTilesAppTests/HealthPerClockTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")

@Test func aBatteryWarningNamesTheClockItIsAbout() {
    let warning = BatteryWarning(threshold: 20, percent: 19)

    #expect(BatteryAlertWords.body(for: warning, on: "Desk") == "Desk: 19% left, and falling.")
}

// The kitchen clock is unplugged; the desk carries on and the glyph, which is
// about the selected clock, stays online.
@Test @MainActor func aClockThatStopsAnsweringStallsOnlyItsOwnTiles() async {
    let transport = RoutingByHostTransport(online: ["10.0.0.5"])
    let schedule = Metronome()
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        transport: transport,
        sleep: schedule.sleep,
        clocks: [desk, kitchen],
        tiles: [
            TileRecord(key: TileKey(clockId: desk.id, connectorId: "claude"), policy: TilePolicyRecord(TileDefaults.claude)),
            TileRecord(key: TileKey(clockId: kitchen.id, connectorId: "claude"), policy: TilePolicyRecord(TileDefaults.claude)),
        ],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.start()
    #expect(await waitUntil { subject.isDeviceOnline && schedule.parked == 2 })
    schedule.tick()

    #expect(await waitUntil { onDesk.calls.contains("run:claude") })
    #expect(await waitUntil({ inKitchen.calls.contains("run:claude") }, limit: 0.2) == false)
    await subject.teardown()
}
```

`BatteryWarning(threshold:percent:)` is `BatteryTrajectory`'s. Re-verify its initialiser. `RoutingByHostTransport` is a new double in `Doubles.swift`: it answers `onlineStats` for a request whose URL host is in `online`, and throws `URLError(.cannotConnectToHost)` otherwise. It is modelled on `StubTransport`. `testModel` builds one `ClockHealth` per clock over its `transport`, each on `AwtrixDevice(host: clock.address, transport:)`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'KeyedBatteryHistoryTests|BatteryHistoryMigrationTests|HealthPerClockTests'`
Expected: FAIL. `extra argument 'hardwareIdentity'`, `cannot find 'BatteryHistoryMigration'`, and `extra argument 'on'`.

- [ ] **Step 3: Key the store.** In `BatteryHistoryStore.swift`, replace `private static let key = "batteryHistory"` (and its comment) with:

```swift
    /// One key per clock, under the name the clock gives itself, so two
    /// clocks' trends never mix and a clock that moves address keeps its own.
    /// The uid stays inside the series as well: samples without it beside them
    /// cannot be checked against the device now answering, which is the one
    /// thing that makes resuming safe.
    public static func key(forHardwareIdentity identity: String) -> String {
        "batteryHistory.\(identity)"
    }
```

Replace the stored `defaults` and `init` with:

```swift
    private let defaults: UserDefaults
    /// The clock this store resumes for, or nil while it has never answered —
    /// and so has nothing of its own to resume.
    private let hardwareIdentity: String?

    public init(defaults: UserDefaults = .standard, hardwareIdentity: String?) {
        self.defaults = defaults
        self.hardwareIdentity = hardwareIdentity
    }
```

In `storedHistory()`, the first line becomes:

```swift
        guard let hardwareIdentity,
            let data = defaults.data(forKey: Self.key(forHardwareIdentity: hardwareIdentity))
        else { return nil }
```

and in `save(_:)` the write becomes:

```swift
        // Under the clock the series itself names, so a clock that learns its
        // name on this very poll still lands its first series where the next
        // launch, which reads the name off the clock record, will look.
        defaults.set(data, forKey: Self.key(forHardwareIdentity: history.uid))
```

In `BatteryTrajectoryTests.swift`, the three `UserDefaultsBatteryHistoryStore(defaults: defaults)` calls gain `hardwareIdentity:` with the uid of the series each test stores. That is an arrange change only.

- [ ] **Step 4: The migration step**

```swift
// Sources/PixelClockTilesApp/BatteryHistoryMigration.swift
import Foundation
import PixelClockKit

/// Moves the one stored battery series under the name of the clock it came
/// off, so the clock's own trend resumes on the first launch that keys health
/// by clock.
///
/// The bytes are copied as they are. The series names its clock itself
/// (`BatteryHistory.uid`), so nothing about it has to be decoded beyond that
/// name, and nothing about its readings can be lost in a re-encode. A series
/// that does not name one is not a series this app can trust, and is left.
struct BatteryHistoryMigration {
    static let markerKey = "migration.batteryHistory"
    static let legacyKey = "batteryHistory"

    let defaults: UserDefaults

    func run() {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        if let data = defaults.data(forKey: Self.legacyKey),
            let owner = try? JSONDecoder().decode(Owner.self, from: data) {
            defaults.set(
                data, forKey: UserDefaultsBatteryHistoryStore.key(forHardwareIdentity: owner.uid)
            )
        }
        defaults.set(true, forKey: Self.markerKey)
    }

    private struct Owner: Decodable {
        let uid: String
    }
}
```

- [ ] **Step 5: `ClockHealth`, one per clock.** Move `monitor`, `unansweredPolls` and `followTheClock()`'s body out of `AppModel` into:

```swift
// Sources/PixelClockTilesApp/ClockHealth.swift
import Foundation
import PixelClockKit

/// One clock's answer to "are you there", its battery, and where it went.
///
/// What `AppModel` held for its one clock (`monitor`, `unansweredPolls`,
/// `followTheClock`), one instance per clock, so a clock that stops answering
/// is looked for — and counted — on its own.
@MainActor
final class ClockHealth {
    let clockId: UUID
    private(set) var name: String
    let monitor: DeviceMonitor
    private var unansweredPolls = 0
    private let relocate: AppModel.RelocatingHost?
    private let clocks: ClockStore

    init(clock: ClockRecord, monitor: DeviceMonitor, relocate: AppModel.RelocatingHost?, clocks: ClockStore) {
        self.clockId = clock.id
        self.name = clock.name
        self.monitor = monitor
        self.relocate = relocate
        self.clocks = clocks
    }

    var isOnline: Bool { monitor.isOnline }

    /// One poll: the reading, a crossed threshold if there was one, and the
    /// relocation rule — exactly `AppModel.poll()`'s first and last steps.
    func poll(at now: Date) async -> BatteryWarning? {
        let crossed = await monitor.refresh(at: now)
        await follow()
        return crossed
    }

    private func follow() async {
        // `AppModel.followTheClock()`'s body as Phase 1 left it, with
        // `clock` read as this health's record from `clocks.all()`.
    }
}
```

Move the body of `followTheClock()` into `follow()` verbatim, including Phase 1's `clocks.update` writes of identity and address. Moving the address also rebuilds that clock's session: call back into `AppModel.reloadClocks()` through a closure the model passes. For a TC002 clock, Phase 3's reachability check takes the place of `DeviceMonitor`. Give `ClockHealth` an initialiser taking Phase 3's health object, and keep `poll(at:)`'s signature, answering `nil` for the warning.

- [ ] **Step 6: Poll every clock at once.** In `AppModel`, `healths: [UUID: ClockHealth]` is built beside `sessions` (in `init` and in `reloadClocks()`). `poll()` becomes:

```swift
    private func poll() async {
        let now = Date()
        // Every clock concurrently: a clock inside its 15-second timeout does
        // not hold up the others' readings.
        let crossings = await withTaskGroup(of: (String, BatteryWarning?).self) { group in
            for health in healths.values {
                group.addTask { @MainActor in (health.name, await health.poll(at: now)) }
            }
            var crossed: [(String, BatteryWarning)] = []
            for await (name, warning) in group {
                if let warning { crossed.append((name, warning)) }
            }
            return crossed
        }
        isDeviceOnline = selectedClockId.flatMap { healths[$0]?.isOnline } ?? false
        refreshScheduleLabels()
        deliverWhatTheLaunchOwes()
        reactToAFocusChange()
        refreshVPNIndicators()
        for (name, warning) in crossings { await alerts.warn(warning, on: name) }
    }
```

`deviceIsUnreachable` becomes per clock: `scheduleHold(for key:)` asks `healths[key.clockId]?.monitor.state` where it asked `monitor.state`. `BatteryWarningPresenting.warn(_:)` becomes `warn(_:on clock: String)`. `BatteryAlert` passes the name to `BatteryAlertWords.body(for:on:)`, which prefixes `"\(clock): "` to today's body. `title(for:)` is unchanged. `SpyAlerts` records `(clock, warning)`, and the existing `BatteryAlertTests` pass `on: "Clock"`: arrange only.

In `live()`, after `WeatherLocationMigration`, add `BatteryHistoryMigration(defaults: defaults).run()`. Each AWTRIX clock's `DeviceMonitor` takes `UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: clock.hardwareIdentity)`. From this commit, nothing writes `batteryHistory`.

- [ ] **Step 7: Run to verify it passes**

Run: `swift test --filter 'KeyedBatteryHistoryTests|BatteryHistoryMigrationTests|HealthPerClockTests|BatteryTrajectoryTests|BatteryAlertTests|BatteryPanelTests|DeviceRelocationWiringTests'`
Expected: PASS. 10 new tests, and the battery and relocation tests unchanged apart from their arranges.

- [ ] **Step 8: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `save` writes under `hardwareIdentity ?? "unknown"` instead of `history.uid` | `aSeriesIsSavedUnderTheClockItCameOff` |
| the step writes under `"clock"` instead of `owner.uid` | `theSeriesMovesUnderTheNameOfItsClockByteForByte` |
| delete the step's marker guard | `aSecondBatteryHistoryMigrationChangesNothing` |
| `poll()` sets `isDeviceOnline` from any clock online | `aClockThatStopsAnsweringStallsOnlyItsOwnTiles` |
| `body(for:on:)` drops the prefix | `aBatteryWarningNamesTheClockItIsAbout` |

- [ ] **Step 9: Commit**

```bash
git add Sources/PixelClockKit/Device/BatteryHistoryStore.swift Sources/PixelClockTilesApp Tests/PixelClockKitTests Tests/PixelClockTilesAppTests
git commit -m "feat: health per clock and battery warnings that name it, batteryHistory migrated"
```

---

### Task B15: Custody per clock — and `borrowedOverlay` migrates

**Files:**
- Modify: `Sources/PixelClockKit/Device/BorrowedOverlayStore.swift` (keyed by clock)
- Create: `Sources/PixelClockTilesApp/BorrowedOverlayMigration.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`live()`: run the step; each AWTRIX session's `borrowedOverlays:`)
- Create: `Tests/PixelClockKitTests/KeyedOverlayTests.swift`, `Tests/PixelClockTilesAppTests/BorrowedOverlayMigrationTests.swift`
- Modify (arrange only): `Tests/PixelClockKitTests/WeatherConnectorTests.swift` (5 constructor calls), `Tests/PixelClockTilesAppTests/AppShellTests.swift` (2)

**Interfaces:**
- Produces: `UserDefaultsBorrowedOverlayStore(defaults:clockId:)` and `static func key(forClock:)`; `BorrowedOverlayMigration` (marker `migration.borrowedOverlay`). The loan moves only onto an AWTRIX first clock: a TC002 answering at the old address has no overlay to give back to.

**Template:** B14's keyed battery store, and the loan-safety argument in Phase 1 D3.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PixelClockKitTests/KeyedOverlayTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Test func eachClocksOverlayLoanIsKeptApart() throws {
    let suite = "overlay-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let desk = UUID(), kitchen = UUID()
    let loan = BorrowedOverlay(before: "clear", applied: "rain", borrower: "weather")
    UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: desk).record(loan)

    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: desk).borrowedOverlay() == loan)
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: kitchen).borrowedOverlay() == nil)

    UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: kitchen).forget()
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: desk).borrowedOverlay() == loan)
}
```

```swift
// Tests/PixelClockTilesAppTests/BorrowedOverlayMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let loan = ["before": "clear", "applied": "rain", "borrower": "weather"]

@Test func anOutstandingLoanMovesOntoTheClockItWasTakenFrom() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        let moved = UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id)
        #expect(moved.borrowedOverlay() == BorrowedOverlay(before: "clear", applied: "rain", borrower: "weather"))
    }
}

// The desk clock at that address is a TC002 now. It has no overlay, and a loan
// from the clock that used to answer there is nothing it could give back.
@Test func aTC002AtTheOldAddressInheritsNoLoan() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(.ulanziTC002, in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).borrowedOverlay() == nil)
        #expect(defaults.bool(forKey: BorrowedOverlayMigration.markerKey))
    }
}

@Test func withNoClockYetTheOverlayStepHasNotRun() throws {
    try withFreshDefaults { defaults in
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(defaults.bool(forKey: BorrowedOverlayMigration.markerKey) == false)
    }
}

@Test func theBorrowedOverlayMigrationLeavesTheOldKeyAsItWas() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(defaults.dictionary(forKey: BorrowedOverlayMigration.legacyKey) as? [String: String] == loan)
    }
}

@Test func theBorrowedOverlayMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(defaults.writes.last == BorrowedOverlayMigration.markerKey)
    }
}

// The loan was given back on the clock since the first run. The old copy must
// not come back and restore a sky over the user's own overlay.
@Test func aSecondBorrowedOverlayMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)
        BorrowedOverlayMigration(defaults: defaults).run()
        UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).forget()

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).borrowedOverlay() == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'KeyedOverlayTests|BorrowedOverlayMigrationTests'`
Expected: FAIL. `extra argument 'clockId'`, and `cannot find 'BorrowedOverlayMigration'`.

- [ ] **Step 3: Implement.** In `BorrowedOverlayStore.swift`, replace `private static let key = "borrowedOverlay"` with:

```swift
    /// One loan per clock. Two AWTRIX clocks each lend their own overlay, and
    /// a loan given back on one says nothing about the other.
    public static func key(forClock clockId: UUID) -> String {
        "borrowedOverlay.\(clockId.uuidString)"
    }
```

Add `private let key: String` beside `defaults`, change `init(defaults:)` to `init(defaults: UserDefaults = .standard, clockId: UUID)` setting `self.key = Self.key(forClock: clockId)`, and turn the three `forKey: Self.key` into `forKey: key`. Then:

```swift
// Sources/PixelClockTilesApp/BorrowedOverlayMigration.swift
import Foundation
import PixelClockKit

/// Moves an outstanding overlay loan onto the clock it was taken from.
///
/// The first clock, because that is the one every loan so far was taken from.
/// Only while it is still an AWTRIX clock: a loan is an AWTRIX overlay, and a
/// TC002 now answering at the same address has none to give back to. Copied as
/// stored, three strings, so nothing is re-encoded on the way.
struct BorrowedOverlayMigration {
    static let markerKey = "migration.borrowedOverlay"
    static let legacyKey = "borrowedOverlay"

    let defaults: UserDefaults

    func run() {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        guard let clock = ClockStore(defaults: defaults).all().first else { return }
        if clock.model == .awtrix3, let loan = defaults.dictionary(forKey: Self.legacyKey) {
            defaults.set(loan, forKey: UserDefaultsBorrowedOverlayStore.key(forClock: clock.id))
        }
        defaults.set(true, forKey: Self.markerKey)
    }
}
```

In `live()`, add `BorrowedOverlayMigration(defaults: defaults).run()` after `BatteryHistoryMigration`. `makeSession`'s AWTRIX branch passes `borrowedOverlays: UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id)`. From this commit, nothing writes `borrowedOverlay`. The seven existing test calls gain `clockId:` with any fixed UUID: arrange only.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter 'KeyedOverlayTests|BorrowedOverlayMigrationTests|WeatherConnectorTests|AppShellTests'`
Expected: PASS. 7 new tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `key(forClock:)` answers `"borrowedOverlay"` | `eachClocksOverlayLoanIsKeptApart` |
| `if clock.model == .awtrix3, let loan` → `if let loan` | `aTC002AtTheOldAddressInheritsNoLoan` |
| a missing clock writes the marker | `withNoClockYetTheOverlayStepHasNotRun` |
| delete the marker guard | `aSecondBorrowedOverlayMigrationChangesNothing` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Device/BorrowedOverlayStore.swift Sources/PixelClockTilesApp/BorrowedOverlayMigration.swift Sources/PixelClockTilesApp/AppModel.swift Tests
git commit -m "feat: custody per clock, borrowedOverlay migrated"
```

---

### Task B16: Each tile held by its own policy — and quiet hours migrate

The app-wide `FocusGate` stops deciding. From this commit on, each tile's `TilePolicy` answers what holds it, the settings' quiet-hour pickers are gone, and `quietStartHour` / `quietEndHour` are no longer written.

**Files:**
- Create: `Sources/PixelClockTilesApp/QuietHoursMigration.swift`, `Tests/PixelClockTilesAppTests/QuietHoursMigrationTests.swift`, `Tests/PixelClockTilesAppTests/TilePolicyHoldTests.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`init` takes `focusStatus:` and `now:`; `scheduleHold(for:)`; `duringTheQuietWindow(_:)`; `quietHours`, `setQuietHours` and `focusRule` deleted)
- Modify: `Sources/PixelClockTilesApp/SettingsSheet.swift` (`quietHoursSection` becomes `focusSection`: the Full Disk Access sentence only)
- Modify: `Sources/PixelClockTilesApp/FocusGate.swift` (`FocusRuleLine.whichFocusesSilenceDependsOnFullDiskAccess` rewritten)
- Modify: `Tests/PixelClockTilesAppTests/Doubles.swift` (`testModel`: `focus:` and `quietHours:` become `focusStatus:` and `now:`), `FocusGateTests.swift`, `FocusModeTests.swift`, `MicrophoneGateTests.swift`, `AppModelTests.swift`, `PanelRenderingTests.swift` (ported; see Step 6)

**Interfaces:**
- Consumes: `MacFocus(reading:)` (A11), `TilePolicy.hold(in:atHour:)` (A6), the mapping (B2), `Connector.defaultPolicy` (B3)
- Produces: `QuietHoursMigration` (marker `migration.quietHours`). `AppModel`'s holds per tile: the clock first, then the tile's policy (`paused` / `hours` / `focus`), then the microphone for an audible tile. The nightly refresh may not spend while its tile's hold is `.hours`.

**Template:** `AppModel.scheduleHold(for:)` itself, whose order (the clock, then quiet, then the microphone) is kept. The quiet rules are now asked of every tile, not only audible ones. That is safe for every shipped tile: the weather's row silences nothing, and Claude's silences exactly what `ClaudeFocusAudience` hid.

- [ ] **Step 1: Write the failing migration tests**

```swift
// Tests/PixelClockTilesAppTests/QuietHoursMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let audible: Set<String> = ["anecdotes"]

private func savedTheOldWay(from start: Int, to end: Int, in defaults: UserDefaults) {
    defaults.set(start, forKey: QuietHoursMigration.startKey)
    defaults.set(end, forKey: QuietHoursMigration.endKey)
}

@Test func theQuietHoursBecomeTheWindowOfEveryAudibleTile() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 22, to: 7, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .quiet(HourWindow(startHour: 22, endHour: 7)))
    }
}

// The window only ever held what could be heard. The weather and the Claude
// figure drew straight through it, and still do.
@Test func aSilentTileKeepsItsHours() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 22, to: 7, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("weather", in: defaults)?.policy.window == nil)
        #expect(tile("claude", in: defaults)?.policy.window == nil)
    }
}

// Midnight is an hour somebody can choose, and `integer(forKey:)` answers 0 for
// a key never written.
@Test func aWindowStartingAtMidnightIsNotMistakenForNone() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 0, to: 6, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .quiet(HourWindow(startHour: 0, endHour: 6)))
    }
}

@Test func hoursNeverSavedAreTheWindowTheAppKept() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .quiet(HourWindow(startHour: 23, endHour: 8)))
    }
}

// Only the hours move. The Focus rule is the anecdote row's, which is what the
// app did with Focuses before tiles.
@Test func theQuietHoursMigrationLeavesTheFocusRuleToTheDefaults() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.focus == nil)
    }
}

@Test func theQuietHoursMigrationLeavesTheOldKeysAsTheyWere() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 22, to: 7, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(defaults.object(forKey: QuietHoursMigration.startKey) as? Int == 22)
        #expect(defaults.object(forKey: QuietHoursMigration.endKey) as? Int == 7)
    }
}

@Test func theQuietHoursMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(defaults.writes.last == QuietHoursMigration.markerKey)
    }
}

@Test func aSecondQuietHoursMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try QuietHoursMigration(defaults: defaults, audible: audible).run()
        let edited = try #require(tile("anecdotes", in: defaults))
        TileStore(defaults: defaults).update(edited) { $0.policy.window = .always }

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .always)
    }
}
```

- [ ] **Step 2: Write the failing hold tests**

```swift
// Tests/PixelClockTilesAppTests/TilePolicyHoldTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Every tile is held by its own policy now, and the words the panel shows are
// the ones `FocusGate` used, so nothing the user reads changes with the move.

private func tileOf(_ connector: String, _ policy: TilePolicy, on clock: ClockRecord) -> TileRecord {
    TileRecord(key: TileKey(clockId: clock.id, connectorId: connector), policy: TilePolicyRecord(policy))
}

private let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")

@Test @MainActor func aTileInItsQuietHoursIsHeldAndSaysSo() async {
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "anecdotes")],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .noFocus),
        now: { atHour(3) },
        clocks: [clock],
        tiles: [tileOf("anecdotes", TileDefaults.anecdotes, on: clock)]
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["anecdotes"] == .held(AppModel.duringQuietHours) })
    #expect(host.calls.contains("run:anecdotes") == false)
    await subject.teardown()
}

@Test @MainActor func aTileIsHeldByAFocusItDoesNotWorkIn() async {
    let host = SpyHost()
    // Silent, like the real Claude tile: the quiet rules reach it now only
    // because every tile carries a policy.
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")),
        now: { atHour(12) },
        clocks: [clock],
        tiles: [tileOf("claude", TileDefaults.claude, on: clock)]
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["claude"] == .held(AppModel.duringFocus) })
    #expect(host.calls.contains("run:claude") == false)
    await subject.teardown()
}

// The weather's row silences nothing, so a Sleep at 3 a.m. still draws the
// temperature — what the audible-only rule guaranteed before.
@Test @MainActor func theWeatherRunsThroughTheNightAndEveryFocus() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [StubConnector(id: "weather", isAudible: false)],
        host: host,
        sleep: schedule.sleep,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")),
        now: { atHour(3) },
        clocks: [clock],
        tiles: [tileOf("weather", TileDefaults.weather, on: clock)]
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:weather") })
    await subject.teardown()
}

// A record Phase 1 wrote has no Focus rule and no hours, and is read as its
// connector's row — which for the anecdotes is the night off.
@Test @MainActor func aTileStoredBeforePhaseFourIsHeldByItsConnectorsRow() async {
    let host = SpyHost()
    let old = TileRecord(
        key: TileKey(clockId: clock.id, connectorId: "anecdotes"),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 1_800)
    )
    let subject = testModel(
        connectors: [AnecdoteRowConnector()],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .noFocus),
        now: { atHour(3) },
        clocks: [clock],
        tiles: [old]
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["anecdotes"] == .held(AppModel.duringQuietHours) })
    await subject.teardown()
}

/// A stub whose default is the anecdote row, so the mapping has a row to read.
private struct AnecdoteRowConnector: Connector {
    let id = "anecdotes"
    let displayName = "Anecdotes"
    let defaultInterval: TimeInterval = 1_800
    var defaultPolicy: TilePolicy { TileDefaults.anecdotes }
    func read() async throws -> String { "" }
    var awtrixFace: AwtrixFace<String> { AwtrixFace { AwtrixDelivery(text: $0) } }
}
```

The held tests leave `sleep:` at its `parked` default: `reschedule` publishes the hold before its first sleep, so no tick is needed to read it. The strings move from `FocusGate` to `AppModel` in Step 4, unchanged: `duringFocus = "Focus is on"`, `duringQuietHours = "quiet hours"`. `testModel`'s `focus:` and `quietHours:` become `focusStatus:` (default `StubFocusStatus(access: .authorized)`) and `now:` (default `{ atHour(12) }`, noon, for the reason `focusGate(_:at:)` defaulted to it) at `focus:`'s place in the signature.

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter 'QuietHoursMigrationTests|TilePolicyHoldTests'`
Expected: FAIL. `cannot find 'QuietHoursMigration'`, and `extra argument 'focusStatus'`.

- [ ] **Step 4: Implement.** The step:

```swift
// Sources/PixelClockTilesApp/QuietHoursMigration.swift
import Foundation
import PixelClockKit

/// Turns the app-wide quiet hours into the window of every audible tile.
///
/// Audible tiles only, because the window only ever held those: the weather and
/// the Claude figure drew through it. Hours never written are the window the
/// app kept anyway, 23:00–08:00, and that is what is written — read through
/// `object(forKey:)`, so a window starting at midnight is not mistaken for
/// none.
struct QuietHoursMigration {
    static let markerKey = "migration.quietHours"
    static let startKey = "quietStartHour"
    static let endKey = "quietEndHour"

    let defaults: UserDefaults
    /// The connectors that can be heard, by id.
    let audible: Set<String>

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        let hours: HourWindow
        if let start = defaults.object(forKey: Self.startKey) as? Int,
            let end = defaults.object(forKey: Self.endKey) as? Int {
            hours = HourWindow(startHour: start, endHour: end)
        } else {
            hours = HourWindow(startHour: 23, endHour: 8)
        }
        let store = TileStore(defaults: defaults)
        try store.replaceAll(store.all().map { tile in
            guard audible.contains(tile.key.connectorId) else { return tile }
            var quiet = tile
            quiet.policy.window = .quiet(hours)
            return quiet
        })
        defaults.set(true, forKey: Self.markerKey)
    }
}
```

In `AppModel`:
- Replace `private let focus: FocusGate` and `@Published private(set) var quietHours` with `private let focusStatus: any FocusStatusReading` and `private let now: @Sendable () -> Date`. In `init`, `focus: FocusGate` and `quietHours:` become `focusStatus: any FocusStatusReading` and `now: @escaping @Sendable () -> Date = Date.init`.
- Move `FocusGate.duringFocus` and `duringQuietHours` onto `AppModel` as `static let`, unchanged.
- Add:

```swift
    /// The Focus the Mac is in, as every tile reads it.
    private var currentFocus: MacFocus { MacFocus(reading: focusStatus) }
    /// The hour every tile's window is read against, off the injected clock so
    /// a test can stand at three in the morning.
    private var currentHour: Int { Calendar.current.component(.hour, from: now()) }

    /// A tile's policy as stored, with anything a record from before Phase 4
    /// does not say taken from its connector's row.
    private func policy(of key: TileKey) -> TilePolicy? {
        guard let record = tiles.all().first(where: { $0.key == key }) else { return nil }
        // The VPN is not in the registry (it is not a scene connector), so its
        // row is named here.
        let row = key.connectorId == VPNConnector.id
            ? TileDefaults.vpn
            : registry.connector(id: key.connectorId)?.defaultPolicy
                ?? TilePolicy(refreshSeconds: record.policy.refreshSeconds)
        return TilePolicy(record.policy, defaults: row)
    }
```

- `scheduleHold(for key:)` becomes:

```swift
    private func scheduleHold(for key: TileKey) -> String? {
        if clockIsUnreachable(key.clockId) { return Self.deviceUnreachable }
        switch policy(of: key)?.hold(in: currentFocus, atHour: currentHour) {
        case .paused?: return Self.switchedOff
        case .hours?: return Self.duringQuietHours
        case .focus?: return Self.duringFocus
        case nil: break
        }
        guard isAudible(key.connectorId) else { return nil }
        return busyMicrophone.map { MicrophoneGate.inUse($0.name) }
    }

    /// Whether this tile's own hours are what holds it — the one hold the
    /// nightly refresh may not spend through.
    private func duringTheQuietWindow(_ key: TileKey) -> Bool {
        policy(of: key)?.hold(in: currentFocus, atHour: currentHour) == .hours
    }
```

- `tick(_:)` reads `duringTheQuietWindow(key)`. Delete `focusRule`, `setQuietHours(_:)` and `quietHours`. `requestAccess()` moves onto `focusStatus.requestAccess()` at the same call site.
- `live()`: `QuietHoursMigration(defaults: defaults, audible: Set(registry.all.filter(\.isAudible).map(\.id))).run()` after `BorrowedOverlayMigration`. Pass `focusStatus: SystemFocusStatus()` where it passed `FocusGate(status: focusStatus)`, and drop `quietHours: QuietWindow.stored(in: defaults)`.

In `SettingsSheet`, `quietHoursSection` becomes a `focusSection` holding one `Text` with `FocusRuleLine.whichFocusesSilenceDependsOnFullDiskAccess`, and the `hourPicker` helper goes. In `FocusGate.swift`, that sentence becomes:

```swift
    static let whichFocusesSilenceDependsOnFullDiskAccess =
        "macOS tells apps only that some Focus is on, never which one. Without "
            + "Full Disk Access every Focus reads as Other Focus to your tiles; "
            + "grant it in System Settings › Privacy & Security › Full Disk "
            + "Access and Work, Personal, Do Not Disturb and Sleep are told apart."
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter 'QuietHoursMigrationTests|TilePolicyHoldTests'`
Expected: PASS. 12 new tests.

- [ ] **Step 6: Port the tests that built a `FocusGate` or a `QuietWindow` into a model.** This is a porting rule, not a rewrite. In each test, `focus: focusGate(status, at: h)` becomes `focusStatus: status, now: { atHour(h) }`, and `quietHours: w` becomes the audible tile's `window: .quiet(HourWindow(startHour: w.startHour, endHour: w.endHour))` in `tiles:`. `#expect` lines stay as they are, except where the table below says a test goes.

| File | Tests | Fate |
| --- | --- | --- |
| `FocusGateTests.swift` | the 5 window tests (`aQuietWindow…`, `aWindowSaysItself…`, `aWindowStartingAtMidnight…`) | stay until B20 deletes `QuietWindow`; `HourWindowTests` (A2) and `aWindowStartingAtMidnightIsNotMistakenForNone` (this task) carry them |
| `FocusGateTests.swift` | the 11 `FocusGate.rule` / `.silence` tests | ported to `MacFocus.resolved` + `TileDefaults.anecdotes.hold` in `TilePolicyHoldTests.swift`, same names, same claims. Two claims change on purpose (spec § Persistence, "Behaviour that changes on purpose"): a Focus outside the four now holds the anecdotes, where "everyOtherFocusIsSpokenThrough" spoke through Fitness. Its port asserts `.focus` for `com.apple.focus.fitness` and speaks for Work and Personal |
| `FocusGateTests.swift` | the 12 schedule tests (`anActiveFocusSilencesTheSchedule` … `macOSIsAskedForFocusAccessOnceAtLaunch`) | ported by the rule above, same names |
| `FocusGateTests.swift` | `theQuietHoursTheUserPicksAreSavedAndReadBack`, `theWindowTheUserSetsIsTheOneTheScheduleObeys` | deleted with `setQuietHours`: there are no app-wide hours left to pick. The second's claim lives on as `aTileInItsQuietHoursIsHeldAndSaysSo` |
| `FocusGateTests.swift` | the 4 `FocusRuleLine.text(for:)` tests | deleted with the caption. The one sentence that stays is pinned by `theSettingsSayWhatFullDiskAccessBuys` |
| `FocusModeTests.swift` | the 8 `DoNotDisturbDatabase` tests | untouched |
| `FocusModeTests.swift` | the 5 gate tests (`doNotDisturbAndSleepSilenceTheSchedule` … `theModeIsNotConsultedWhileTheCenterIsUnauthorized`) | ported to `MacFocus.resolved` + the anecdotes row, same names |
| `FocusModeTests.swift` | `theSettingsSayWhatFullDiskAccessBuys` | its expected string becomes the new sentence |
| `PanelRenderingTests.swift` | `thePanelSaysWhichRuleIsInForce`, `theQuietHoursAreVisibleAndEditableInTheSettings` | deleted with the pickers. Replaced by one test that the settings show the Full Disk Access sentence and no hour picker |
| `MicrophoneGateTests.swift`, `AppModelTests.swift` | every `focusGate(…)` argument | the porting rule |

- [ ] **Step 7: Run everything**

Run: `swift test`
Expected: PASS. Before this task's commit, count the removed tests against the table: 6 deleted, and the rest ported by name.

- [ ] **Step 8: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `case .hours?: return Self.duringQuietHours` → `return nil` | `aTileInItsQuietHoursIsHeldAndSaysSo` |
| `guard isAudible(…) else { return nil }` moved above the policy switch (the old audible-only rule) | `aTileIsHeldByAFocusItDoesNotWorkIn` |
| `policy(of:)` uses `TilePolicy(refreshSeconds:)` as the row for every connector | `aTileStoredBeforePhaseFourIsHeldByItsConnectorsRow` |
| `duringTheQuietWindow` compares with `.focus` | the ported `theNightlyRefreshDoesNotRunInsideTheUsersQuietHours` |
| the step reads `defaults.integer(forKey:)` | `aWindowStartingAtMidnightIsNotMistakenForNone` |
| the step writes the window on every tile | `aSilentTileKeepsItsHours` |

- [ ] **Step 9: Commit**

```bash
git add Sources/PixelClockTilesApp Tests/PixelClockTilesAppTests
git commit -m "feat: each tile held by its own policy, quiet hours migrated"
```

---

### Task B17: Take a tile off, or bring it back, when the Focus or the hour changes

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`reactToAFocusChange()` becomes `reconcileTiles()`; `lastSeenFocus` and `focusGated` go; `live()` passes `showsNow: { true }`)
- Delete: `Sources/PixelClockTilesApp/ClaudeFocusAudience.swift`, `Sources/PixelClockTilesApp/FocusGatedConnector.swift`
- Modify: `Tests/PixelClockTilesAppTests/FocusChangeTests.swift` (ported), `Tests/PixelClockTilesAppTests/ClaudeFocusAudienceTests.swift` (ported and renamed `ClaudeTilePolicyTests.swift`), `Tests/PixelClockTilesAppTests/Doubles.swift` (`focusGated:` goes)

**Interfaces:**
- Consumes: `TileVerdicts` (B12), `TilePolicy.runs` (A6)
- Produces: `func reconcileTiles()`, called by the Focus watcher, by every poll (which is also the hour hand) and after a save (B19). A tile whose policy stopped allowing it is retracted through its session (`restoreDeviceState(borrowedBy: connectorId)`: `removeApp` on AWTRIX, `{}` on the TC002). A silent tile whose policy started allowing it is run at once. An audible one waits for its beat, because a Focus ending must not tell a joke on the spot.

**Template:** `reactToAFocusChange()`, generalised from one gated connector to every tile. The hour boundary is new: a Claude tile given working hours has to leave at the end of them.

- [ ] **Step 1: Port the tests.** `FocusChangeTests`' four tests keep their names and assertions. Their arrange builds a Claude tile with `TileDefaults.claude` in place of `gated(status)`, and their act calls `subject.reconcileTiles()` in place of `reactToAFocusChange()`. `ClaudeFocusAudienceTests`' four tests become `ClaudeTilePolicyTests`, same names, each asserting `TileDefaults.claude.runs(in: MacFocus(reading: status), atHour: 12)` where it asserted `ClaudeFocusAudience.shows(status)`. Add three tests to `FocusChangeTests.swift`:

```swift
// Working hours end without any Focus changing: the minute hand has to notice.
@Test @MainActor func aTileWhoseWorkingHoursEndIsTakenOffTheClock() async {
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let hour = HourBox(18)
    let host = SpyHost()
    var office = TileDefaults.claude
    office.window = .active(HourWindow(startHour: 9, endHour: 19))
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .noFocus),
        now: { atHour(hour.value) },
        clocks: [clock],
        tiles: [TileRecord(key: TileKey(clockId: clock.id, connectorId: "claude"), policy: TilePolicyRecord(office))]
    )

    subject.reconcileTiles()
    hour.value = 19
    subject.reconcileTiles()

    #expect(await waitUntil { host.calls.contains("restore:claude") })
}

// An audible tile coming back waits for its beat. A Focus ending must not
// tell a joke on the spot.
@Test @MainActor func anAudibleTileBroughtBackWaitsForItsBeat() async {
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode"))
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "anecdotes")],
        host: host,
        focusStatus: status,
        now: { atHour(12) },
        clocks: [clock],
        tiles: [TileRecord(key: TileKey(clockId: clock.id, connectorId: "anecdotes"), policy: TilePolicyRecord(TileDefaults.anecdotes))]
    )

    subject.reconcileTiles()
    status.nowIn(.mode("com.apple.focus.work"))
    subject.reconcileTiles()

    #expect(await waitUntil({ host.calls.contains("run:anecdotes") }, limit: 0.1) == false)
}

@Test @MainActor func aPausedTileIsNeitherTakenOffNorBroughtBackByAFocus() async {
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let host = SpyHost()
    var paused = TileDefaults.claude
    paused.isPaused = true
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: status,
        now: { atHour(12) },
        clocks: [clock],
        tiles: [TileRecord(key: TileKey(clockId: clock.id, connectorId: "claude"), policy: TilePolicyRecord(paused))]
    )

    subject.reconcileTiles()
    status.nowIn(.mode("com.apple.sleep.sleep-mode"))
    subject.reconcileTiles()

    #expect(host.calls.isEmpty)
}

private final class HourBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hour: Int
    init(_ hour: Int) { self.hour = hour }
    var value: Int {
        get { lock.withLock { hour } }
        set { lock.withLock { hour = newValue } }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'FocusChangeTests|ClaudeTilePolicyTests'`
Expected: FAIL. `value of type 'AppModel' has no member 'reconcileTiles'`.

- [ ] **Step 3: Implement.** Replace `reactToAFocusChange()`, `lastSeenFocus` and `focusGated` with:

```swift
    /// What every tile's policy says now, against what it said the last time.
    private var verdicts = TileVerdicts()

    /// Takes off the clock the tiles whose policy stopped allowing them, and
    /// brings back the silent ones it started allowing.
    ///
    /// Leaving is an explicit retraction, because nothing on the clock removes
    /// an app for being unrefreshed until its lifetime runs out — a Sleep that
    /// started at midnight would leave the figure lit until a quarter past, and
    /// on the TC002, whose lifetime is emulated, for the whole of it. Arriving
    /// is a run for a silent tile only: an audible one waits for its own beat.
    ///
    /// Paused tiles are left out: a pause is the user's own hand and is
    /// retracted when it is saved (B19), not re-decided by a Focus. Only a
    /// CHANGE is acted on, so the minute hand costs nothing when nothing moved.
    func reconcileTiles() {
        let focus = currentFocus
        let hour = currentHour
        var now: [TileKey: Bool] = [:]
        for record in tiles.all() where record.key.connectorId != VPNConnector.id {
            guard let policy = policy(of: record.key), !policy.isPaused else { continue }
            now[record.key] = policy.runs(in: focus, atHour: hour)
        }
        let change = verdicts.update(now)
        for key in change.left { retract(key) }
        for key in change.arrived where !isAudible(key.connectorId) { runNow(key) }
    }
```

`retract(_ key:)` (B13) calls `session(for: key)?.restoreDeviceState(borrowedBy: key.connectorId)`. The Focus watcher and `poll()` call `reconcileTiles()` where they called `reactToAFocusChange()`. `live()` passes `showsNow: { true }` to `ClaudeUsageConnector`, because the tile decides now. Delete the two files and the `focusGated:` parameters.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter 'FocusChangeTests|ClaudeTilePolicyTests'`
Expected: PASS, 11 tests (4 ported and 3 new, plus 4 ported).

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `where !isAudible(key.connectorId)` removed | `anAudibleTileBroughtBackWaitsForItsBeat` |
| `!policy.isPaused` removed from the guard | `aPausedTileIsNeitherTakenOffNorBroughtBackByAFocus` |
| `now[record.key] = policy.runs(in: focus, atHour: 12)` (the hour ignored) | `aTileWhoseWorkingHoursEndIsTakenOffTheClock` |
| `for key in change.left { runNow(key) }` | `switchingIntoAFocusThatHidesItTakesItOffTheClockAtOnce` |

- [ ] **Step 6: Commit**

```bash
git add -A Sources/PixelClockTilesApp Tests/PixelClockTilesAppTests
git commit -m "feat: take a tile off or bring it back when the Focus or the hour changes"
```

---

### Task B18: VPN tiles light their lamps — and the always-on corners migrate

**Files:**
- Create: `Sources/PixelClockTilesApp/VPNTileMigration.swift`, `Tests/PixelClockTilesAppTests/VPNTileMigrationTests.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`refreshVPNIndicators()` becomes `refreshLamps()`; `vpnLamps` and `vpnPresence` become `vpn: VPNConnector`; `teardown()` puts out every claimed lamp; `live()`)
- Delete: `Sources/PixelClockTilesApp/VPNIndicatorPolicy.swift`, `Sources/PixelClockTilesApp/VPNLampDisplay.swift`, `Tests/PixelClockTilesAppTests/VPNIndicatorPolicyTests.swift` (ported into `LampBoardTests` by B9), `Tests/PixelClockTilesAppTests/VPNLampDisplayTests.swift` (its rules are `IndicatorCustodyTests`', per Phase 2's note)
- Modify: `Tests/PixelClockTilesAppTests/VPNIndicatorWiringTests.swift` (ported)

**Interfaces:**
- Consumes: `VPNConnector` (B8), `LampBoard` (B9), `IndicatorCustody` via `AwtrixClockSession.indicators` (Phase 2), `VPNPresence.isUp` (app)
- Produces: `VPNTileMigration` (marker `migration.vpnTiles`) and `func refreshLamps()`. For every AWTRIX clock, it reads each VPN tile, asks `LampBoard` who owns each lamp, and writes each slot's one answer through that clock's `IndicatorCustody`. The writes stay off the delivery chain. The triggers are the ones `refreshVPNIndicators()` had: the network watcher, the Focus watcher and the poll. The quit puts out every lamp any VPN tile on that clock claims, lit or not, which is what `VPNLampDisplay.clear()` did for its two corners.

**Template:** `refreshVPNIndicators()` and its `vpnPushes` bracket, kept as they are for teardown.

- [ ] **Step 1: Write the failing migration tests**

```swift
// Tests/PixelClockTilesAppTests/VPNTileMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private func vpnTiles(in defaults: UserDefaults) -> [TileRecord] {
    TileStore(defaults: defaults).all().filter { $0.key.connectorId == VPNConnector.id }
}

@Test func theTwoCornersBecomeTwoVPNTilesOnTheFirstClock() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        let tiles = vpnTiles(in: defaults)
        #expect(tiles.map(\.key) == [
            TileKey(clockId: clock.id, connectorId: "vpn", instance: "pritunl"),
            TileKey(clockId: clock.id, connectorId: "vpn", instance: "amnezia"),
        ])
        #expect(tiles.map(\.config) == [
            .vpn(VPNTileConfig(vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000"))),
            .vpn(VPNTileConfig(vpn: "amnezia", slot: .bottomRight, upColour: "#A855F7", whenDown: .off)),
        ])
        #expect(tiles.allSatisfy { $0.policy.refreshSeconds == 60 && $0.policy.isPaused == false })
        // The three tiles already there are left where they were, in front.
        #expect(TileStore(defaults: defaults).all().count == 5)
    }
}

// What each corner followed, read back through the grid: Pritunl in Work only,
// Amnezia in Work and Personal, and neither under a Focus that cannot be named
// — which is what `VPNIndicatorPolicy` did.
@Test func eachTileWorksInTheFocusesItsCornerFollowed() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        let working = vpnTiles(in: defaults).map { tile in
            let policy = TilePolicy(tile.policy, defaults: TileDefaults.vpn)
            return MacFocus.allCases.filter { policy.runs(in: $0, atHour: 12) }
        }
        #expect(working == [[.work], [.work, .personal]])
    }
}

// Written out, so neither falls back to the VPN row's `run`.
@Test func bothVPNTilesHoldOnAFocusThatCannotBeNamedInWhatIsStored() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).map(\.policy.focus?.whenUnknown) == [.hold, .hold])
    }
}

@Test func aTC002HasNoCornersToCarryOver() throws {
    try withFreshDefaults { defaults in
        try storeAClock(.ulanziTC002, in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).isEmpty)
        #expect(defaults.bool(forKey: VPNTileMigration.markerKey))
    }
}

@Test func withNoClockYetTheVPNStepHasNotRun() throws {
    try withFreshDefaults { defaults in
        try VPNTileMigration(defaults: defaults).run()

        #expect(defaults.bool(forKey: VPNTileMigration.markerKey) == false)
    }
}

// A run cut short after the tiles and before the marker runs again from the
// start, and must not leave four.
@Test func aVPNStepCutShortDoesNotAddTheTilesTwice() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try TileStore(defaults: defaults).replaceAll(VPNTileMigration.tiles(on: clock.id))

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).count == 2)
    }
}

@Test func theVPNTileMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        #expect(defaults.writes.last == VPNTileMigration.markerKey)
    }
}

@Test func aSecondVPNTileMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)
        try VPNTileMigration(defaults: defaults).run()
        let removed = TileStore(defaults: defaults).all().filter { $0.key.instance != "amnezia" }
        try TileStore(defaults: defaults).replaceAll(removed)

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).map(\.key.instance) == ["pritunl"])
    }
}
```

- [ ] **Step 2: Port the wiring tests.** `VPNIndicatorWiringTests`' four tests keep their names and assertions. Their arrange builds the two migrated tiles (`VPNTileMigration.tiles(on: clock.id)`) on one AWTRIX clock whose session's `indicators` is an `IndicatorCustody(lamps: RecordingLamps())`, and their act calls `refreshLamps()`. `VPNIndicatorPolicy.tunnelMissing`, `.tunnelUp`, `.privateTunnel` and `.blinkMilliseconds` in their `#expect` lines become the literals the migration writes (`"#FF0000"`, `"#90EE90"`, `"#A855F7"`, `500`): the constants go with the file. Add:

```swift
// A Focus switch hands a shared lamp from one tile to the other in one write:
// the old colour, then the new, and never dark in between.
@Test @MainActor func aSharedLampIsHandedOverInOneWrite() async {
    let lamps = RecordingLamps()
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let work = VPNTileMigration.tiles(on: clock.id)[0]  // Pritunl, top, Work only
    var personal = VPNTileMigration.tiles(on: clock.id)[1]  // Amnezia, moved onto the top lamp
    personal.config = .vpn(VPNTileConfig(vpn: "amnezia", slot: .topRight, upColour: "#A855F7", whenDown: .off))
    personal.policy.focus = FocusRule(silencedIn: [.noFocus, .work, .doNotDisturb, .sleep], whenUnknown: .hold)
    let subject = testModel(
        focusStatus: status,
        now: { atHour(12) },
        vpnPresence: VPNPresence(processes: FixedProcessList(paths: [
            "/Applications/Pritunl.app/Contents/Resources/pritunl-openvpn",
            "/Applications/AmneziaVPN.app/Contents/MacOS/wireguard-go",
        ])),
        clocks: [clock],
        tiles: [work, personal],
        sessions: [clock.id: LampSession(lamps: lamps)]
    )
    subject.refreshLamps()
    #expect(await waitUntil { lamps.written.count == 1 })

    status.nowIn(.mode("com.apple.focus.personal"))
    subject.refreshLamps()

    #expect(await waitUntil { lamps.written.count == 2 })
    #expect(lamps.written.map(\.signal) == [.steady("#90EE90"), .steady("#A855F7")])
}
```

`LampSession` is a new double in `Doubles.swift`. `RecordingLamps` conforms to the kit's `IndicatorLighting` from Phase 2 on. `testModel`'s `vpnPresence:` stays where it is, and the model builds `VPNConnector(isUp: vpnPresence.isUp)` from it:

```swift
/// A session whose lamps are recorded, and that otherwise answers like a
/// healthy clock that runs whatever it is asked to.
final class LampSession: ConnectorRunning, @unchecked Sendable {
    let indicators: IndicatorCustody?

    init(lamps: RecordingLamps) {
        indicators = IndicatorCustody(lamps: lamps)
    }

    func maintain(connectorId: String) async -> MaintenanceResult { .completed }
    func runOnce(connectorId: String) async -> RunResult { .delivered }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .delivered }
    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval { interval }
    func restoreDeviceState(borrowedBy connectorId: String?) async {}
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter 'VPNTileMigrationTests|VPNIndicatorWiringTests'`
Expected: FAIL. `cannot find 'VPNTileMigration'`, and `value of type 'AppModel' has no member 'refreshLamps'`.

- [ ] **Step 4: Implement the step**

```swift
// Sources/PixelClockTilesApp/VPNTileMigration.swift
import Foundation
import PixelClockKit

/// Turns the two always-on VPN corners into two VPN tiles on the clock that
/// showed them.
///
/// Each tile carries what `VPNIndicatorPolicy` hard-coded, and its Focus rule
/// written out: `hold` on a Focus that cannot be named, because today such a
/// Focus leaves both corners dark. Written explicitly, so the tile never falls
/// back to the VPN defaults row, which says `run`.
///
/// On the first clock, which is the one the corners were lit on. A clock that
/// is not AWTRIX has no lamps, so there is nothing to carry over and the step
/// is done. No clock at all is a step that has not run yet.
struct VPNTileMigration {
    static let markerKey = "migration.vpnTiles"

    let defaults: UserDefaults

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        guard let clock = ClockStore(defaults: defaults).all().first else { return }
        if clock.model == .awtrix3 {
            let store = TileStore(defaults: defaults)
            let migrated = Self.tiles(on: clock.id)
            let keys = Set(migrated.map(\.key))
            // A run cut short before its marker left these behind; they are
            // replaced rather than added twice.
            try store.replaceAll(store.all().filter { !keys.contains($0.key) } + migrated)
        }
        defaults.set(true, forKey: Self.markerKey)
    }

    static func tiles(on clockId: UUID) -> [TileRecord] {
        [
            tile(
                on: clockId,
                lamp: VPNTileConfig(
                    vpn: WatchedVPN.pritunl.id, slot: .topRight,
                    upColour: "#90EE90", whenDown: .blink("#FF0000")
                ),
                workingIn: [.work]
            ),
            tile(
                on: clockId,
                lamp: VPNTileConfig(
                    vpn: WatchedVPN.amnezia.id, slot: .bottomRight,
                    upColour: "#A855F7", whenDown: .off
                ),
                workingIn: [.work, .personal]
            ),
        ]
    }

    private static func tile(
        on clockId: UUID, lamp: VPNTileConfig, workingIn focuses: Set<MacFocus>
    ) -> TileRecord {
        let named: Set<MacFocus> = [.noFocus, .work, .personal, .doNotDisturb, .sleep]
        let policy = TilePolicy(
            refreshSeconds: TileDefaults.vpn.refreshSeconds,
            focus: FocusRule(silencedIn: named.subtracting(focuses), whenUnknown: .hold)
        )
        return TileRecord(
            key: TileKey(clockId: clockId, connectorId: VPNConnector.id, instance: lamp.vpn),
            policy: TilePolicyRecord(policy),
            config: .vpn(lamp)
        )
    }
}
```

- [ ] **Step 5: Implement `refreshLamps`.** `ConnectorRunning` gains `var indicators: IndicatorCustody? { get }`. `AwtrixClockSession` answers its own, and the TC002 session and `SpyHost` answer nil. Then, in `AppModel`:

```swift
    /// Puts every AWTRIX clock's lamps where its VPN tiles say they belong.
    ///
    /// Each clock's claims are resolved before anything is written, so a lamp
    /// changing hands on a Focus switch is one write. Writes go straight to the
    /// clock's `IndicatorCustody`, off the delivery chain, so a lamp never waits
    /// behind a playing anecdote; the custody writes only what changed.
    func refreshLamps() {
        let focus = currentFocus
        let hour = currentHour
        let byClock = Dictionary(grouping: tiles.all().filter { $0.key.connectorId == VPNConnector.id }, by: \.key.clockId)
        for (clockId, vpnTiles) in byClock {
            guard let indicators = sessions[clockId]?.indicators else { continue }
            let vpn = self.vpn
            let key = nextRunKey
            nextRunKey += 1
            vpnPushes[key] = Task { [weak self] in
                var claims: [LampClaim] = []
                for record in vpnTiles {
                    guard let lamp = record.config?.lamp,
                        let reading = try? await vpn.read(config: lamp),
                        let policy = self?.policy(of: record.key)
                    else { continue }
                    claims.append(LampClaim(
                        key: record.key, slot: lamp.slot, policy: policy,
                        signal: VPNConnector.signal(for: reading)
                    ))
                }
                let covering = Set(vpnTiles.compactMap { $0.config?.lamp?.slot })
                for (slot, signal) in LampBoard.lamps(claims, covering: covering, in: focus, atHour: hour)
                    .sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    await indicators.show(signal, on: slot)
                }
                self?.vpnPushes[key] = nil
            }
        }
    }
```

The push task is created on the main actor and inherits it, so `policy(of:)` is read without a hop. `covering` is every lamp any VPN tile on that clock names. A tile that is paused, or held in this Focus, still keeps its lamp covered, so the lamp goes dark rather than being left as it was. In `teardown()`, after the sessions are restored, every AWTRIX clock's covered lamps get `.off` through its custody. `VPNLampDisplay.clear()` did the same for its two corners, lit or not (Phase 2 D12). `live()` runs `VPNTileMigration(defaults: defaults).run()` after `QuietHoursMigration` and holds `let vpn = VPNConnector(isUp: VPNPresence().isUp)`. The watchers and `poll()` call `refreshLamps()`. `start()` gives each VPN tile no timer of its own: the minute poll is its recheck, as it is today, and a tile's `refresh` below 60 s is read as 60 until the recheck has a loop of its own (the "What later tasks owe" note in B21).

Delete the four files named above.

- [ ] **Step 6: Run to verify it passes**

Run: `swift test --filter 'VPNTileMigrationTests|VPNIndicatorWiringTests|LampBoardTests|IndicatorCustodyTests|IndicatorCustodyWiringTests'`
Expected: PASS. 8 migration tests, 5 wiring tests, and the custody tests unchanged. `IndicatorCustodyWiringTests` (Phase 2) now arranges a migrated installation. Its path assertion, `/api/indicator1` and `/api/indicator3`, holds as written.

- [ ] **Step 7: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| `if clock.model == .awtrix3 {` → `if true {` | `aTC002HasNoCornersToCarryOver` |
| `store.all().filter { !keys.contains($0.key) } + migrated` → `store.all() + migrated` | `aVPNStepCutShortDoesNotAddTheTilesTwice` |
| `whenUnknown: .hold` → `.run` in the step | `bothVPNTilesHoldOnAFocusThatCannotBeNamedInWhatIsStored` |
| a missing clock writes the marker | `withNoClockYetTheVPNStepHasNotRun` |
| `refreshLamps` writes each tile's signal as it reads it, before `LampBoard` | `aSharedLampIsHandedOverInOneWrite` |
| `covering` left empty | the ported `sleepLeavesBothCornersDark` |

- [ ] **Step 8: Commit**

```bash
git add -A Sources/PixelClockTilesApp Tests/PixelClockTilesAppTests
git commit -m "feat: VPN tiles light their lamps through the board, the always-on corners migrated"
```

---

### Task B19: Add, save and remove tiles, with the refusals the design names

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift`
- Create: `Tests/PixelClockTilesAppTests/TileEditingTests.swift`

**Interfaces:**
- Consumes: `TileCatalogue` (B11), `LampConflict` (B10), `Connector.defaultPolicy` (B3), the mapping (B2)
- Produces, on `AppModel`: `enum TileSaveOutcome: Equatable { case saved, refused(String) }`, `func availability(of connectorId: String, on clockId: UUID) -> TileAvailability`, `func addTile(_ connectorId: String, to clockId: UUID, instance: String = "", config: TileConfig? = nil) -> TileSaveOutcome`, `func saveTile(key: TileKey, policy: TilePolicy, config: TileConfig?) -> TileSaveOutcome` and `func removeTile(_ key: TileKey)`. Phase 5's Add tile menu and tile detail call them. Until then the tests do.

**Template:** `setEnabled(_:for:)` and `commit(_:for:)`: persist, then reschedule, then give device state back when switched off.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockTilesAppTests/TileEditingTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let tc002 = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

@Test @MainActor func aNewTileStartsFromItsConnectorsDefaults() {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])

    #expect(subject.addTile("claude", to: desk.id) == .saved)

    #expect(subject.storedPolicy(of: TileKey(clockId: desk.id, connectorId: "claude")) == StubConnector(id: "claude").defaultPolicy)
}

@Test @MainActor func aTileTheClockCannotTakeIsRefusedWithTheMenusReason() {
    let subject = testModel(connectors: [StubConnector(id: "anecdotes")], clocks: [desk, tc002], tiles: [])

    #expect(subject.addTile("anecdotes", to: tc002.id) == .refused("not supported on TC002"))
}

@Test @MainActor func aSecondTileOfOneConnectorOnOneClockIsRefused() {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)

    #expect(subject.addTile("claude", to: desk.id) == .refused("already on Desk"))
}

@Test @MainActor func aVPNTileClaimingAHeldLampIsRefusedInTheDesignsWords() {
    let subject = testModel(clocks: [desk], tiles: VPNTileMigration.tiles(on: desk.id))
    let amnezia = TileKey(clockId: desk.id, connectorId: "vpn", instance: "amnezia")
    var onTop = TilePolicy(refreshSeconds: 60, focus: FocusRule(silencedIn: [.noFocus, .doNotDisturb, .sleep], whenUnknown: .hold))
    onTop.window = .active(HourWindow(startHour: 10, endHour: 19))

    let outcome = subject.saveTile(
        key: amnezia,
        policy: onTop,
        config: .vpn(VPNTileConfig(vpn: "amnezia", slot: .topRight, upColour: "#A855F7", whenDown: .off))
    )

    #expect(outcome == .refused("Pritunl and Amnezia both claim the top lamp: Work, 10:00–19:00"))
}

// A pause takes the tile's app off the clock at once — on the TC002 that is
// the only thing that ever will.
@Test @MainActor func pausingATileTakesItOffItsClockAtOnce() async {
    let host = SpyHost()
    let subject = testModel(connectors: [StubConnector(id: "claude")], host: host, clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)
    var paused = StubConnector(id: "claude").defaultPolicy
    paused.isPaused = true

    _ = subject.saveTile(key: TileKey(clockId: desk.id, connectorId: "claude"), policy: paused, config: nil)

    #expect(await waitUntil { host.calls.contains("restore:claude") })
}

@Test @MainActor func removingATileTakesItOffItsClockAndOutOfTheList() async {
    let host = SpyHost()
    let subject = testModel(connectors: [StubConnector(id: "claude")], host: host, clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)

    subject.removeTile(TileKey(clockId: desk.id, connectorId: "claude"))

    #expect(await waitUntil { host.calls.contains("restore:claude") })
    #expect(subject.storedPolicy(of: TileKey(clockId: desk.id, connectorId: "claude")) == nil)
}
```

`storedPolicy(of:)` is an internal read-back added for these tests and for Phase 5's tile detail. It is the B16 `policy(of:)` under a name that says it reads the store.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TileEditingTests`
Expected: FAIL. `value of type 'AppModel' has no member 'addTile'`.

- [ ] **Step 3: Implement**

```swift
    enum TileSaveOutcome: Equatable {
        case saved
        /// Not saved, with the sentence to show beside the control that asked.
        case refused(String)
    }

    /// What the Add tile menu shows for a connector on a clock.
    func availability(of connectorId: String, on clockId: UUID) -> TileAvailability {
        guard let clock = clocks.first(where: { $0.id == clockId }),
            let candidate = candidate(connectorId)
        else { return .notListed }
        return TileCatalogue.availability(of: candidate, on: clock, tiles: tiles.all(), clocks: clocks)
    }

    func addTile(
        _ connectorId: String, to clockId: UUID, instance: String = "", config: TileConfig? = nil
    ) -> TileSaveOutcome {
        let key = TileKey(clockId: clockId, connectorId: connectorId, instance: instance)
        switch availability(of: connectorId, on: clockId) {
        case let .unavailable(reason):
            return .refused(reason)
        case .notListed:
            return .refused("already on \(clocks.first { $0.id == clockId }?.name ?? "this clock")")
        case .available:
            break
        }
        if tiles.all().contains(where: { $0.key == key }) {
            return .refused("already on \(clocks.first { $0.id == clockId }?.name ?? "this clock")")
        }
        let starting = connectorId == VPNConnector.id
            ? TileDefaults.vpn
            : registry.connector(id: connectorId)?.defaultPolicy ?? TileDefaults.weather
        return saveTile(key: key, policy: starting, config: config)
    }

    /// Stores what the tile detail says, unless a VPN lamp is claimed by
    /// another tile at the same moment. A pause takes the tile's app off its
    /// clock at once; the schedule is rebuilt either way.
    func saveTile(key: TileKey, policy: TilePolicy, config: TileConfig?) -> TileSaveOutcome {
        if let lamp = config?.lamp,
            let conflict = LampConflict.check(
                LampTile(key: key, name: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn, slot: lamp.slot, policy: policy),
                against: lampTiles(on: key.clockId)
            ) {
            return .refused(conflict.message)
        }
        let wasRunning = storedPolicy(of: key).map { !$0.isPaused } ?? false
        tiles.update(TileRecord(key: key, policy: TilePolicyRecord(policy))) {
            $0.policy = TilePolicyRecord(policy)
            $0.config = config
        }
        if wasRunning && policy.isPaused { retract(key) }
        if key.connectorId == VPNConnector.id { refreshLamps() } else { reschedule(key) }
        reconcileTiles()
        return .saved
    }

    func removeTile(_ key: TileKey) {
        timers.removeValue(forKey: key)?.cancel()
        try? tiles.replaceAll(tiles.all().filter { $0.key != key })
        if key.connectorId == VPNConnector.id { refreshLamps() } else { retract(key) }
    }

    func storedPolicy(of key: TileKey) -> TilePolicy? { policy(of: key) }

    private func candidate(_ connectorId: String) -> TileCandidate? {
        if connectorId == VPNConnector.id { return TileCandidate(vpn) }
        return registry.connector(id: connectorId).map { TileCandidate($0) }
    }

    private func lampTiles(on clockId: UUID) -> [LampTile] {
        tiles.all().compactMap { record in
            guard record.key.clockId == clockId, let lamp = record.config?.lamp,
                let policy = policy(of: record.key)
            else { return nil }
            return LampTile(key: record.key, name: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn, slot: lamp.slot, policy: policy)
        }
    }
```

`policy(of:)` (B16) already reads a VPN tile against `TileDefaults.vpn`, because `registry` does not hold the VPN.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TileEditingTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutate, one site at a time**

| Mutation | Must fail |
| --- | --- |
| delete the `LampConflict.check` block | `aVPNTileClaimingAHeldLampIsRefusedInTheDesignsWords` |
| `if wasRunning && policy.isPaused { retract(key) }` removed | `pausingATileTakesItOffItsClockAtOnce` |
| `removeTile` without `retract` | `removingATileTakesItOffItsClockAndOutOfTheList` |
| `addTile` skips `availability` | `aTileTheClockCannotTakeIsRefusedWithTheMenusReason` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/TileEditingTests.swift
git commit -m "feat: add, save and remove tiles, with the refusals the design names"
```

---

### Task B20: Remove what is left of the app-wide gate

**Files:**
- Modify: `Sources/PixelClockTilesApp/FocusGate.swift` (delete `QuietWindow`, `QuietRule`, `struct FocusGate` and `FocusRuleLine.text(for:)`; keep `FocusAccess`, `ActiveFocusMode`, `FocusStatusReading`, `SystemFocusStatus`, `DoNotDisturbDatabase` and the one `FocusRuleLine` sentence), then `git mv` it to `Sources/PixelClockTilesApp/FocusStatus.swift`
- Delete: `Tests/PixelClockTilesAppTests/FocusGateTests.swift` (its remaining 5 window tests; `HourWindowTests` carries them)
- Modify: `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` (`showsNow` and `Failure.outOfFocus` go), `Tests/PixelClockKitTests/ClaudeUsageTests.swift` (their tests go), **only once lane C has landed**. If it has not, this step moves to lane C's merge and is noted there.
- Modify: `Tests/PixelClockTilesAppTests/Doubles.swift` (`focusGate(_:at:)` goes)
- Modify: `Sources/PixelClockTilesApp/PanelWidth.swift` (the doc comment that names `QuietWindow.stored(in:)` names `Coordinates`' old reader instead: comment only)

**Interfaces:**
- Consumes: nothing new
- Produces: nothing. `rg -n 'QuietWindow|QuietRule|FocusGate\b|focusGate\(|ClaudeFocusAudience|FocusGatedConnector|VPNIndicatorPolicy|VPNLampDisplay' Sources Tests` prints nothing.

- [ ] **Step 1: Delete, then build**

Run: `swift build 2>&1 | grep -E "error|warning:"`
Expected: no output. Any caller the earlier tasks missed shows up here, and it is ported by B16's rule, not rewritten.

- [ ] **Step 2: Test the whole suite**

Run: `swift test`
Expected: PASS. The count is the count after B19, less the 5 window tests. A test that vanished outside that list is a defect in this task.

- [ ] **Step 3: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: remove the app-wide Focus gate, now that every tile carries its own"
```

---

### Task B21: The hand-off for several clocks and tiles

**Files:**
- Modify: `docs/HANDOFF.md`, `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md`

- [ ] **Step 1: Correct the spec in place** (surgical, English):
  - `FocusState` → `MacFocus`, and `.none` → `.noFocus`, with one sentence each on why (decisions 1 and 2).
  - § Adding a tile: `availability` has three answers, and `.notListed` is rule 2's.
  - § TilePolicy: an empty window restricts nothing in either direction. `whenUnknown` alone decides the Focus that cannot be named. A refresh tie takes the longer step.
  - § Connector: no `Config` associated type. A tile's settings are `TileRecord.config`, and they reach a connector through the connector its clock's session is built with (decision 12). The VPN is a lamp connector, not a `Connector`, and `awtrixFace` stays required (decision 9).
  - § ClockSession: backoff by `TileKey` holds because a session is one clock. The chain stays keyed by connector id (decision 14).
  - § Persistence: the five Phase 4 rows with their markers, and the TC002 exception for the overlay loan and the VPN tiles.

- [ ] **Step 2: Add to `HANDOFF.md`** a section "Added by PixelClockTiles phase 4", with these hardware checks:
  1. Two VPN tiles sharing a lamp (move Amnezia onto the top lamp in Personal only). Switching Work → Personal goes green → purple with no dark frame in between. This is spec check 2.
  2. With Full Disk Access on a signed build, Work and Personal are told apart by `com.apple.focus.work` and `com.apple.focus.personal`: the migrated Pritunl lamp lights in Work only. This is spec check 3, and every tile depends on it now.
  3. An upgrade from Phase 3 keeps the weather place, the quiet hours and both VPN corners. On the desk's TC002, no VPN tiles appear and no old overlay is restored.
  4. Unplug a second AWTRIX clock: the first keeps delivering, and the glyph stays online while the first is selected.

  And "What later tasks owe":
  - Phase 5 owes the UI named in the Contact points table.
  - A VPN tile's recheck below 60 s needs a loop of its own (B18 reads it as the poll's minute).
  - `ClaudeUsageConnector.showsNow` goes with lane C if B20 could not remove it.
  - The uploaded-icon record (`UserDefaultsUploadedIconStore`, one key) does not say which clock an icon went to, and "Remove installed icons" acts on one device. With two AWTRIX clocks it needs keying per clock, like the overlay loan. No phase owns it yet.

- [ ] **Step 3: Lint and commit**

Run: `markdownlint docs/HANDOFF.md docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md` if it is installed. Otherwise say so and go on.

```bash
git add docs/HANDOFF.md docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md
git commit -m "docs: hand-off for several clocks and tiles, and the spec brought in line"
```

---

## Self-review

- **Spec coverage, Phase 4 row.** A session per clock: B13. Scheduling by `TileKey`: B13, with holds in B16. `TilePolicy`, its grid and the overlap check in place of `FocusGate`: A1–A11, B2, B10, B16, B20. `TileCatalogue.availability`: B11, B19. VPN tiles with lamp ownership: B4, B5, B8, B9, B18. The keyed weather cache: B1. Retraction on a Focus change: B17. Health and battery history per session: B14. The Phase 4 migration rows: B7, B14, B15, B16, B18.
- **Verified outside the tree.** A1–A11 in a scratch package (Swift 6.3.3, tools 6.0): 72 new tests green beside the untouched `FocusGateTests` and `FocusModeTests` running on the edited `FocusGate.swift`. There, 27 single-site mutations and the 3 guard deletions of A6 all died. B1, B2, B4–B12, the keyed stores of B14 and B15 and the five migration steps were compiled in a second scratch package, against Phase 1's `ClockStore`, `TileStore` and records copied from its plan and a stand-in for Phase 2's `Connector`, `AwtrixFace` and `AwtrixDelivery`: 94 new tests green beside the 9 existing weather-source tests, and every mutation in their tables died. B3 and B13–B19 edit code that Phases 1–3 are still writing, and they are verified by their own steps. `swift test --filter <FileName>` selects the free `@Test` functions of that file, which was checked.
- **Type consistency.** `MacFocus`, `HourWindow`, `RefreshScale`, `FocusRule`, `TileWindow`, `TileHold`, `TilePolicy`, `TileDefaults`, `PolicyGrid`, `TileConfig`, `VPNTileConfig`, `VPNConnector`, `LampClaim`, `LampBoard`, `LampTile`, `LampConflict`, `Instancing`, `TileCandidate`, `TileAvailability`, `TileCatalogue` and `TileVerdicts` are spelled the same in every task that uses them. None collides with SwiftUI, AppKit, Intents or Combine (checked in a scratch module importing all of them).
