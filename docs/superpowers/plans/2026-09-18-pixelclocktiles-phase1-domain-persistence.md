# PixelClockTiles Phase 1 — Domain and Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app a clock record and a tile record, migrate an existing installation into them, and switch its readers over: the launch takes its one clock from `clocks` instead of `deviceHost`, and each connector's cadence and pause come from its tile instead of `connector.<id>`.

**Architecture:** The records and their stores sit in `PixelClockKit`, next to the `UserDefaults` stores already there. The migration steps sit in `PixelClockTilesApp`, next to the types that own the old keys. Neither `ConnectorHost` nor `AppModel`'s schedule changes shape. Both already read connector settings through the `SettingsStore` protocol, and `AppModel.live()` hands them a `TileSettingsStore` in place of the `UserDefaultsSettingsStore`. The clock gets the same treatment: `AppModel` takes a `ClockRecord` where it took a host string, and it writes what it learns into `ClockStore` where it used to write two defaults keys.

**Tech Stack:** Swift 6.3.3, SwiftPM tools 6.0, macOS 14, swift-testing, Foundation `UserDefaults` + `JSONEncoder`. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md` (§ Clock, § Tile, § Persistence and migration, § Phases row 1). Read it with `docs/HANDOFF.md` ("How this branch finds defects", "What later tasks owe").

**House format:** `docs/superpowers/plans/2026-08-17-awtrix-connectors.md`. Its Global Constraints still bind.

## Global Constraints

- Swift tools version `6.0`, platform floor `.macOS(.v14)`. Swift 6 strict concurrency is on; a type that crosses an actor boundary is `Sendable`.
- **No third-party dependencies**, ever. Foundation, SwiftUI, AppKit and Network are Apple's own frameworks and are in scope.
- All source comments, identifiers, commit messages and documentation are English.
- Names are phase 0's: module `PixelClockKit` in `Sources/PixelClockKit/`, executable target `PixelClockTilesApp` in `Sources/PixelClockTilesApp/`, tests in `Tests/PixelClockKitTests/` and `Tests/PixelClockTilesAppTests/`. AWTRIX-specific types keep their names (`AwtrixDevice`, `AwtrixError`).
- Device under development: `192.168.1.72`. No test reaches the network or the clock: every test goes through `StubTransport` or no transport at all. The address appears only in fixtures and in `AppModel.defaultDeviceHost`.
- Mutation discipline from HANDOFF: **mutate one site at a time**, and **after adding a guard, re-run the mutations of the guards it sits in front of**. Every task below lists its guards, the mutation and the test that has to fail.
- Old keys are read and never written or removed. Each migration step writes its marker last, and a second run changes nothing.
- The tree is green before and after every commit. Under heavy load four wall-clock tests go red that have nothing to do with this phase (HANDOFF, "State"). Before calling a red run a defect, check what else the machine was doing.

---

## What this phase makes true

1. `AppModel.live()` drives the first clock in `clocks`. The address typed into the settings, the address a relocation found and the identity a poll learned all land on that clock's record, and `deviceHost` / `deviceUID` are never written again.
2. `ConnectorHost` and `AppModel` read and write each connector's pause, refresh and last delivery through the tile on that clock, and `connector.<id>` is never written again.
3. An installation from before this phase comes up with the clock at the same address, the same identity, every connector's switch and interval as they were, and the cadence resuming from the last delivery.

## Decisions this plan takes

**D1 — The persistence seam is `SettingsStore`, and only the object behind it changes.** Today `ConnectorHost.runOnce` and `ConnectorHost.maintain` read `store.settings(for:).isEnabled`, and `AppModel` reads and writes `ConnectorSettings` (`isEnabled`, `intervalPosition`, `lastDeliveredAt`) through `storedSettings(for:)` and `save(_:for:)`. Phase 1 adds `TileSettingsStore: SettingsStore` and swaps it in inside `AppModel.live()`, and nothing in `ConnectorHost` is edited. Phase 2 extracts `DeliveryChain` from `ConnectorHost` at the same time, and that only works if this phase leaves the host's shape alone.

**D2 — How a tile stores its policy in Phase 1.** `TileRecord.policy` is a `TilePolicyRecord` carrying exactly the two fields something reads in Phase 1: `isPaused: Bool` and `refreshSeconds: Int`. It is a persistence record, not Phase 4's `TilePolicy`, which Phase 4 Part A is writing concurrently as a pure value type with the evaluation logic. The stored JSON is `{"isPaused": Bool, "refreshSeconds": Int}` under `policy`. Phase 4 adds the Focus and the hours as optional keys inside `policy` and decodes this shape unchanged; whether through a mapping or by making `TilePolicy` itself `Codable` with these two key names is Phase 4's call. The refresh is stored in seconds, as the spec requires. In Phase 1 it is read back through today's `IntervalScale` (5 min … 12 h), because the slider still binds to a position on that scale.

**D3 — Rows migrate in the phase that stops the app writing their source key. Moved, not justified.** The spec's table is one migration with one marker. Five of its rows copy values that the old code keeps writing or using after Phase 1:

| Old key | Still written or read by the old code after Phase 1 | Where the row goes |
| --- | --- | --- |
| `quietStartHour` / `quietEndHour` | the hour pickers in `SettingsSheet` | Phase 4, with `TilePolicy` |
| `weatherLocation` | `LocationField` | Phase 4, with the keyed weather cache |
| the always-on VPN lamps | constants in `VPNIndicatorPolicy`, read by `VPNLampDisplay` | Phase 4, with VPN tiles |
| `borrowedOverlay` | `DeviceCustody`, on every weather delivery | the phase that keys custody by clock |
| `batteryHistory` | `DeviceMonitor`, on every poll | the phase that keys health by clock |

Migrated now, each of these becomes a snapshot that goes stale while the old UI keeps editing the key, and the phase that finally reads it would pick up the stale copy without saying so. For `borrowedOverlay` that is a correctness defect and not just lost data: a copy of a loan that has since been given back would make the per-clock custody restore an old sky over the user's own overlay. The old keys are never removed, so a later step reads the value current on the day it lands. The marker rule does not force one migration either. Each step has its own marker, written last, so each one either finished or runs again from the old keys. Phase 1 therefore has two steps: `migration.clocks` (`deviceHost`, `deviceUID`) and `migration.tiles` (`connector.<id>`), and both land in the same commit as the reader that retires their source keys.

**D4 — `deviceUID` migrates, which the spec's table leaves out.** `AppModel.followTheClock()` sends `deviceUID` to relocation today. Left behind, the first outage after the upgrade would relocate with no identity, which falls back to "exactly one clock is advertising", the rule HANDOFF records as the one that moves the app onto a neighbour's clock. It becomes `ClockRecord.hardwareIdentity`.

**D5 — An installation that never saved `deviceHost` gets `AppModel.defaultDeviceHost`.** That is the address its launch was using, so the migrated clock is the one the app was already driving. Phase 5 decides whether a fresh install should start with no clocks at all ("No clocks yet") and changes this branch then.

**D6 — `hardwareIdentity` is optional.** A migrated installation whose clock never answered has none until the first answering poll.

**D7 — Phase 1 owns `ClockModel`.** The record needs it and Phase 3a's model detection produces it. Defined in Task 1 at `Sources/PixelClockKit/Clocks/ClockModel.swift`, raw values `awtrix3` and `ulanziTC002`. This bends "a type lands with its reader" by one parallel wave: the reader is Phase 3a's, and the alternative is two definitions of one enum colliding at merge.

**D8 — Every registered connector gets a tile, whether it was ever configured or not.** Before tiles, every registered connector ran on the one clock. `connector.<id>` only existed once somebody had touched a switch or a delivery had happened. A tile per registered connector, with the connector's own defaults where no key exists, is what the old app was actually doing, and it is decision 8 of the spec ("defaults copied from the connector when the tile is created"). A connector registered after the migration ran gets its tile from its first saved choice (`TileSettingsStore.save` inserts).

**D9 — A delivery never rounds the stored refresh onto the scale.** `AppModel.noteDelivery` saves the whole `ConnectorSettings` value after every delivery, and its `intervalPosition` is a snapped reading of the stored seconds. `TileSettingsStore.save` rewrites `refreshSeconds` only when the position differs from the one the stored seconds snap to, which means the slider moved. Without that guard a refresh the old scale cannot show (60 s for a VPN recheck, Phase 4's 30 s) would be rounded to 5 min one delivery after it was set.

**D10 — Store updates apply the change to the stored record, not to the caller's copy.** `AppModel` holds this launch's `ClockRecord`, while the stored one may already carry an address typed for the next launch. A poll writing the identity by writing its copy back would put the old address over it. `ClockStore.update` and `TileStore.update` apply a closure to whatever is stored, or insert the caller's record when nothing is stored.

**D11 — Three commits.** Tasks 1–3 make one commit and Tasks 4–7 another, because a record may only land in the commit that gives it a production reader, and the reader can only switch in the same commit as the migration that fills it. Without the migration, every existing installation would come up on the default address with default intervals. Tasks 1, 2, 4, 5 and 6 each end with their tests green and their files staged. Task 8 is documentation.

## tea-rags impact enrichment

Rerank `{imports 0.5, churn 0.3, ownership 0.2}` (codegraph has no fan-in for Swift here: every file reports `fanIn 0`, so blast radius below comes from call sites counted by search). Fix rate = commits whose subject starts `fix` over all commits touching the file.

| File (new name) | Owner | Churn | Fix rate | Blast radius | This plan |
| --- | --- | --- | --- | --- | --- |
| `Sources/PixelClockTilesApp/AppModel.swift` | artk0de (100%) | 31 | 42% (13) | `init` has 4 call sites; `live()` is the composition root | edited in Tasks 3 and 7 only |
| `Sources/PixelClockTilesApp/MenuPanel.swift` | artk0de | 21 | 48% (10) | `DeviceHostField.save` has 1 production caller and 7 test callers | `DeviceHostField.save` only (Task 3) |
| `Sources/PixelClockTilesApp/SettingsSheet.swift` | artk0de | 11 | 0% | — | one doc comment (Task 3) |
| `Sources/PixelClockKit/Scheduling/ConnectorSettings.swift` | artk0de | 3 | 33% (1) | `SettingsStore`: 3 conformers, read by `ConnectorHost` and `AppModel` | not edited; `TileSettingsStore` conforms |
| `Sources/PixelClockKit/Scheduling/IntervalScale.swift` | artk0de | 1 | 0% | slider, `ConnectorSettings.interval` | not edited; read by the adapter and the migration |
| `Sources/PixelClockKit/Scheduling/ConnectorHost.swift` | artk0de | 11 | 27% (3) | Phase 2 is rewriting it | **not edited** (D1) |
| `Tests/PixelClockTilesAppTests/Doubles.swift` | artk0de | 24 | 33% (8) | `testModel` backs most app tests | `testModel` and one helper (Task 3) |
| `Tests/PixelClockTilesAppTests/AppShellTests.swift` | artk0de | 16 | 44% (7) | — | 7 tests: storage read moved (Task 3) |
| `Tests/PixelClockTilesAppTests/AppModelTests.swift` | artk0de | 21 | 48% (10) | — | 4 tests + 1 constructor call (Task 3) |
| `Tests/PixelClockTilesAppTests/DeviceRelocationWiringTests.swift` | artk0de | 1 | 0% | — | 6 tests: storage read moved (Task 3) |
| every file under `Clocks/`, `Tiles/`, the migrations, their tests | — (new) | — | — | — | Tasks 1, 2, 4–7 |

**Coordinated change:** the `AppModel.init` signature, `testModel`, the helper at `Doubles.swift` around line 832 and `AppModelTests.swift` around line 1330 all change in Task 3 together, or the test target does not compile.

**High blast radius:** `AppModel.swift` (42% fixes, and Phase 2 is inside it right now). Its edits are confined to `live()`, `init`, two stored properties, the `typedHost` observer and `followTheClock()`. Every edit has a composition-root test.

**Silo:** one author across the repository, so every task is owner-reviewed by default.

**Proven templates** (fallback read, sanctioned for this repo while its tea-rags index is drifting; locality L1, same module):
- `Sources/PixelClockKit/Device/UploadedIconStore.swift` — `UserDefaultsUploadedIconStore` (3 commits, 1 fix): one key, read-modify-write under a **static** `NSLock`. Its comment records 95 lost records in 200 with a per-instance lock. `ClockStore` and `TileStore` copy that shape.
- `Sources/PixelClockKit/Scheduling/ConnectorSettings.swift` — `UserDefaultsSettingsStore`: a key that does not decode reads as absent. Both new stores do the same, and the tile migration reads old keys through this very type.
- `ConnectorSettings.lastDeliveredAt`: an optional field decodes as absent from a key written before it existed. This is the rule Phase 4 relies on to extend `TilePolicyRecord`.
- `Tests/PixelClockKitTests/CatalogueIconInstallerTests.swift` — `concurrentRecordsThroughTwoInstancesAreNeverLostEither`: sixteen concurrent writes through two instances, sized so the test decides without starving the timing tests.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/PixelClockKit/Clocks/ClockModel.swift` (new) | Which firmware a clock runs |
| `Sources/PixelClockKit/Clocks/ClockRecord.swift` (new) | One clock as the settings keep it |
| `Sources/PixelClockKit/Clocks/ClockStore.swift` (new) | The `clocks` key: read, replace, update in place, the first clock a launch drives |
| `Sources/PixelClockKit/Tiles/TileRecord.swift` (new) | `TileKey`, `TilePolicyRecord`, `TileRecord` |
| `Sources/PixelClockKit/Tiles/TileStore.swift` (new) | The `tiles` key: read, replace, update in place |
| `Sources/PixelClockKit/Tiles/TileSettingsStore.swift` (new) | One clock's tiles, served as the `SettingsStore` the schedule and the host already read |
| `Sources/PixelClockTilesApp/ClockMigration.swift` (new) | `deviceHost`, `deviceUID` → one clock; marker `migration.clocks` |
| `Sources/PixelClockTilesApp/TileMigration.swift` (new) | `connector.<id>` → a tile per registered connector; marker `migration.tiles` |
| `Sources/PixelClockTilesApp/AppModel.swift` | Runs both steps, drives the first clock, writes what it learns to the record, hands out `TileSettingsStore` |
| `Sources/PixelClockTilesApp/MenuPanel.swift` | `DeviceHostField.save` writes the address to the clock record |
| `Tests/PixelClockTilesAppTests/RecordingDefaults.swift` (new) | Defaults that remember the order keys were written in |
| `Tests/PixelClockTilesAppTests/RecordWiringTests.swift` (new) | Composition root: the launch reads records, and the migration reaches them |

## Contact points with parallel lanes

| File / symbol | Other lane | What this plan does to it |
| --- | --- | --- |
| `AppModel.live(defaults:transport:anecdoteStore:)` | Phase 0 (the key copy between bundle domains), Phase 2 (`ClockSession` replaces `ConnectorHost` here) | Task 3: runs `ClockMigration`, builds the device from `ClockStore.firstClock(orCreatingAt:)`, passes `clock:` to `AppModel`. Task 7: removes `let store = UserDefaultsSettingsStore(defaults: defaults)`, and after the last `registry.register` adds `TileMigration` plus `let store = TileSettingsStore(defaults: defaults, clockId: clock.id)`. Phase 0's copy of the old domain has to run **before** `ClockMigration`; if phase 0 put it inside `live()`, both steps go directly beneath it. Whatever Phase 2 builds in place of `ConnectorHost` takes this `store` where `ConnectorHost(store:)` takes it now |
| `AppModel.init(deviceHost:…)` | Phase 2 (`host:` parameter) | Task 3: `deviceHost: String` becomes `clock: ClockRecord`; adds `private var clock: ClockRecord` and `private let clocks: ClockStore`. Every other parameter is left alone |
| `AppModel.followTheClock()` | Phase 2 (health), Phase 4 (relocation per clock) | Task 3: reads the remembered identity from `clock.hardwareIdentity`; writes identity and address through `clocks.update` instead of `defaults.set` |
| `AppModel.typedHost` `didSet` | Phase 5 (settings UI) | Task 3: `DeviceHostField.save(typedHost, to: clocks, for: clock)` |
| `AppModel.deviceHostKey`, `.deviceUIDKey` | — | Task 3: doc comments only; `ClockMigration` is now their only production reader |
| `Connector.defaultInterval` | Phase 2 (connectors split into `read` + `awtrixFace`; the spec's `trigger`) | Task 7 reads it in `live()`: `registry.all.map { (id: $0.id, defaultInterval: $0.defaultInterval) }`. `TileMigration` takes plain tuples so that it does not depend on the protocol. If Phase 2 renames the property, this line changes with `AppModel.resolved(_:in:)` |
| `ConnectorHost` and its `SettingsStore` seam | Phase 2 | not edited |
| `DeviceHostField.save` (`MenuPanel.swift`) | Phase 5 (`MenuPanel` split) | Task 3: new signature `save(_:to: ClockStore, for: ClockRecord)` |
| `SettingsSheet.deviceHostSection` doc comment | Phase 5 | Task 3: one sentence |
| `Tests/…/Doubles.swift`: `testModel(…)`, the `AppModel(` call around line 832 | Phase 2 (host doubles) | Task 3: `testModel` gains `hardwareIdentity: String? = nil` after `deviceHost`, and both constructor calls pass `clock:` |
| `Tests/…/AppModelTests.swift` around line 1330 | Phase 2 | Task 3: `AppModel(deviceHost:)` becomes `AppModel(clock:)` |
| `ClockModel` | Phase 3a (model detection) | Task 1 defines it. 3a imports it and does not declare its own |
| `ClockRecord.id`, `.hardwareIdentity` | Phase 3a (`UlanziCustody` owned-names store, detection) | `ownedApps.<clockId>` is keyed by `ClockRecord.id.uuidString`; a TC002's `devSn` goes in `hardwareIdentity` |
| names `TileKey`, `TileRecord`, `TilePolicyRecord`, `TileStore`, `TileSettingsStore`, `ClockRecord`, `ClockStore` | Phase 4 Part A (pure `TilePolicy` types) | reserved by this plan; Part A must not declare them. Part A's refresh in `Int` seconds matches `refreshSeconds` |
| `docs/HANDOFF.md`, the design spec | Phase 0 (path renames) | Task 8 appends sections and replaces the migration table |

---

### Task 1: The clock record and its store

**Files:**
- Create: `Sources/PixelClockKit/Clocks/ClockModel.swift`
- Create: `Sources/PixelClockKit/Clocks/ClockRecord.swift`
- Create: `Sources/PixelClockKit/Clocks/ClockStore.swift`
- Test: `Tests/PixelClockKitTests/ClockStoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `public enum ClockModel: String, Codable, Sendable { case awtrix3, ulanziTC002 }`
  - `public struct ClockRecord: Codable, Sendable, Equatable` — `id: UUID` (let), `name: String`, `model: ClockModel`, `address: String`, `hardwareIdentity: String?`; `init(id: UUID = UUID(), name: String, model: ClockModel, address: String, hardwareIdentity: String? = nil)`
  - `public final class ClockStore: @unchecked Sendable` — `static let key = "clocks"`, `init(defaults: UserDefaults = .standard)`, `func all() -> [ClockRecord]`, `func replaceAll(_ clocks: [ClockRecord]) throws`, `func update(_ clock: ClockRecord, _ change: (inout ClockRecord) -> Void)`, `func firstClock(orCreatingAt address: String) -> ClockRecord`
- Production callers, all in Task 3: `ClockMigration.run()` (`replaceAll`), `AppModel.live()` (`firstClock(orCreatingAt:)`), `AppModel.followTheClock()` and `DeviceHostField.save` (`update`).

- [ ] **Step 1: Confirm the baseline**

Run: `ls Sources/PixelClockKit/Scheduling/ConnectorSettings.swift Sources/PixelClockTilesApp/AppModel.swift && swift build`
Expected: both paths listed and `Build complete!`. If the old names are still on disk, phase 0 has not landed; stop here.

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/PixelClockKitTests/ClockStoreTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The shape later phases decode, written out rather than produced by the
// encoder under test: a test that encodes and decodes with the same code would
// pass through any rename. Two clocks, so both raw values are pinned.
@Test func clocksAreReadFromTheShapeTheyAreStoredIn() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let desk = try #require(UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11"))
    let kitchen = try #require(UUID(uuidString: "0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D"))
    defaults.set(
        Data(
            #"""
            [{"id":"6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11","name":"Desk","model":"awtrix3",\#
            "address":"192.168.1.72","hardwareIdentity":"awtrix_a07f9c"},\#
            {"id":"0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D","name":"Kitchen",\#
            "model":"ulanziTC002","address":"192.168.1.80"}]
            """#.utf8
        ),
        forKey: "clocks"
    )

    #expect(
        ClockStore(defaults: defaults).all() == [
            ClockRecord(
                id: desk, name: "Desk", model: .awtrix3, address: "192.168.1.72",
                hardwareIdentity: "awtrix_a07f9c"
            ),
            ClockRecord(id: kitchen, name: "Kitchen", model: .ulanziTC002, address: "192.168.1.80"),
        ]
    )
}

@Test func aKeyThatDoesNotDecodeReadsAsNoClocks() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not clocks".utf8), forKey: ClockStore.key)

    #expect(ClockStore(defaults: defaults).all().isEmpty)
}

// Read back through a second store over the same defaults, because that is
// what a relaunch is.
@Test func replacedClocksSurviveARelaunchInOrder() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clocks = [
        ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5"),
        ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6"),
    ]

    try ClockStore(defaults: defaults).replaceAll(clocks)

    #expect(ClockStore(defaults: defaults).all() == clocks)
}

// The defect this shape exists to prevent. The model holds this launch's copy
// of its clock; the stored record may already carry an address typed for the
// NEXT launch. A poll writing the identity must not write the copy's address
// back over it.
@Test func anUpdateChangesTheStoredClockRatherThanTheCopyItWasGiven() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let thisLaunch = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    try store.replaceAll([thisLaunch])
    store.update(thisLaunch) { $0.address = "10.0.0.9" }

    store.update(thisLaunch) { $0.hardwareIdentity = "abc" }

    let stored = try #require(store.all().first)
    #expect(stored.address == "10.0.0.9")
    #expect(stored.hardwareIdentity == "abc")
}

@Test func anUpdateStoresAClockThatWasNotStoredYet() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")

    store.update(clock) { $0.hardwareIdentity = "abc" }

    var expected = clock
    expected.hardwareIdentity = "abc"
    #expect(store.all() == [expected])
}

@Test func anUpdateLeavesTheOtherClocksAsTheyWere() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
    try store.replaceAll([desk, kitchen])

    store.update(kitchen) { $0.address = "10.0.0.7" }

    #expect(store.all().first == desk)
    #expect(store.all().last?.address == "10.0.0.7")
}

// What a launch with nothing stored drives. Stored at once, so the identity
// the first poll learns and the address a relocation finds land on a record
// rather than on nothing.
@Test func aLaunchWithNoClockStoredCreatesOneAtTheAddressItWasGiven() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let created = ClockStore(defaults: defaults).firstClock(orCreatingAt: "192.168.1.72")

    #expect(created.name == "Clock")
    #expect(created.model == .awtrix3)
    #expect(created.address == "192.168.1.72")
    #expect(created.hardwareIdentity == nil)
    #expect(ClockStore(defaults: defaults).all() == [created])
}

@Test func theFirstClockStoredIsTheOneALaunchDrives() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
    try store.replaceAll([desk, kitchen])

    #expect(store.firstClock(orCreatingAt: "192.168.1.72") == desk)
    #expect(store.all() == [desk, kitchen])
}

// Sixteen through two instances, for the reason
// `concurrentRecordsThroughTwoInstancesAreNeverLostEither` gives: the lock
// guards the key, so a lock per instance loses records like no lock at all.
@Test func concurrentUpdatesThroughTwoStoresAreNeverLost() async throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = ClockStore(defaults: defaults)
    let second = ClockStore(defaults: defaults)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            let store = index.isMultiple(of: 2) ? first : second
            let clock = ClockRecord(name: "Clock \(index)", model: .awtrix3, address: "10.0.0.\(index)")
            group.addTask { store.update(clock) { _ in } }
        }
    }

    #expect(first.all().count == 16)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ClockStoreTests`
Expected: FAIL — `cannot find 'ClockStore' in scope` (and `ClockRecord`).

- [ ] **Step 4: Write the implementation**

```swift
// Sources/PixelClockKit/Clocks/ClockModel.swift
/// Which firmware a clock runs, and so which adapter drives it.
///
/// Detected when a clock is added, never chosen. Stored by its raw value, so
/// the case names are persisted vocabulary: renaming one strands every record
/// that holds it.
public enum ClockModel: String, Codable, Sendable {
    /// A Ulanzi TC001 on AWTRIX 3.
    case awtrix3
    /// A Ulanzi TC002 on its stock firmware.
    case ulanziTC002
}
```

```swift
// Sources/PixelClockKit/Clocks/ClockRecord.swift
import Foundation

/// One clock this app drives, as the settings keep it.
public struct ClockRecord: Codable, Sendable, Equatable {
    /// This app's key for the clock. It does not move when the address does,
    /// which is why tiles and custody are keyed by it and not by the address.
    public let id: UUID
    /// What the user calls it. "Clock" for the one a migration found.
    public var name: String
    public var model: ClockModel
    /// A host or an IP, as typed or as a relocation found it.
    public var address: String
    /// What the clock calls itself — AWTRIX `uid`, TC002 `devSn` — or nil
    /// until it has answered once. Relocation looks for this, so a moved
    /// lease is the same clock at a new address rather than a new clock.
    public var hardwareIdentity: String?

    public init(
        id: UUID = UUID(),
        name: String,
        model: ClockModel,
        address: String,
        hardwareIdentity: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.address = address
        self.hardwareIdentity = hardwareIdentity
    }
}
```

```swift
// Sources/PixelClockKit/Clocks/ClockStore.swift
import Foundation

/// The clocks, as one JSON array under one `UserDefaults` key.
public final class ClockStore: @unchecked Sendable {
    public static let key = "clocks"

    /// Static, for the reason `UserDefaultsUploadedIconStore`'s lock is:
    /// what is guarded is a key in a defaults domain, and two instances with a
    /// lock each lose updates as if they had none.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// In stored order. A key that does not decode reads as no clocks.
    public func all() -> [ClockRecord] {
        Self.lock.withLock { stored() }
    }

    /// Replaces every clock.
    ///
    /// Throws when the list cannot be encoded rather than writing nothing and
    /// returning, so a migration cannot write its marker over a write that
    /// did not happen.
    public func replaceAll(_ clocks: [ClockRecord]) throws {
        let data = try JSONEncoder().encode(clocks)
        Self.lock.withLock { defaults.set(data, forKey: Self.key) }
    }

    /// Applies `change` to the stored clock with `clock`'s id, or stores
    /// `clock` with the change applied when there is none.
    ///
    /// The change lands on what is STORED, not on `clock`. A model's copy is
    /// this launch's, and the stored address may already hold one typed for
    /// the next launch: writing the copy back would put the old address over
    /// it on the next poll.
    public func update(_ clock: ClockRecord, _ change: (inout ClockRecord) -> Void) {
        Self.lock.withLock {
            var clocks = stored()
            if let index = clocks.firstIndex(where: { $0.id == clock.id }) {
                change(&clocks[index])
            } else {
                var inserted = clock
                change(&inserted)
                clocks.append(inserted)
            }
            write(clocks)
        }
    }

    /// The clock a launch drives: the first one stored, or an AWTRIX clock at
    /// `address` when none is — stored before it is returned, so that what
    /// the launch learns about it has a record to land on.
    public func firstClock(orCreatingAt address: String) -> ClockRecord {
        Self.lock.withLock {
            if let first = stored().first { return first }
            let created = ClockRecord(name: "Clock", model: .awtrix3, address: address)
            write([created])
            return created
        }
    }

    private func stored() -> [ClockRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([ClockRecord].self, from: data)) ?? []
    }

    private func write(_ clocks: [ClockRecord]) {
        guard let data = try? JSONEncoder().encode(clocks) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ClockStoreTests`
Expected: PASS, 9 tests.

- [ ] **Step 6: Mutation check**

Stage first so `git checkout -- <file>` puts back the staged version after each mutation:
`git add Sources/PixelClockKit/Clocks Tests/PixelClockKitTests/ClockStoreTests.swift`

One site at a time. Run `swift test --filter ClockStoreTests` after each mutation, confirm that the named test fails, then `git checkout -- Sources/PixelClockKit/Clocks/ClockStore.swift`.

| Site | Mutation | Must fail |
| --- | --- | --- |
| `update`, found branch | replace `change(&clocks[index])` with `var copy = clock; change(&copy); clocks[index] = copy` | `anUpdateChangesTheStoredClockRatherThanTheCopyItWasGiven` |
| `update`, insert branch | empty the `else` body | `anUpdateStoresAClockThatWasNotStoredYet` |
| `update`, write | `write([clocks[clocks.count - 1]])` instead of `write(clocks)` | `anUpdateLeavesTheOtherClocksAsTheyWere` |
| `firstClock`, `if let first` | delete the line | `theFirstClockStoredIsTheOneALaunchDrives` |
| `firstClock`, `write([created])` | delete the line | `aLaunchWithNoClockStoredCreatesOneAtTheAddressItWasGiven` |
| the lock | `private let lock = NSLock()` and `lock.withLock` for `Self.lock.withLock` in `update` | `concurrentUpdatesThroughTwoStoresAreNeverLost` (run it three times; a lost update is a window) |
| `ClockModel` raw value | `case awtrix3 = "awtrix"` | `clocksAreReadFromTheShapeTheyAreStoredIn` |

- [ ] **Step 7: Leave staged, no commit**

`ClockStore` has no production reader until Task 3, and the spec's Phase 1 row says the records have a reader from the commit that adds them. Task 3 commits Tasks 1–3 together.

---

### Task 2: The clock migration step

**Files:**
- Create: `Sources/PixelClockTilesApp/ClockMigration.swift`
- Create: `Tests/PixelClockTilesAppTests/RecordingDefaults.swift`
- Test: `Tests/PixelClockTilesAppTests/ClockMigrationTests.swift`

**Interfaces:**
- Consumes (existing, verified): `AppModel.deviceHostKey` (`static let deviceHostKey = "deviceHost"`), `AppModel.deviceUIDKey` (`static let deviceUIDKey = "deviceUID"`), `AppModel.defaultDeviceHost` (`static let defaultDeviceHost = "192.168.1.72"`), all members of `@MainActor final class AppModel`. From Task 1: `ClockStore.replaceAll(_:)`, `ClockStore.key`, `ClockRecord`.
- Produces: `@MainActor struct ClockMigration { static let markerKey = "migration.clocks"; let defaults: UserDefaults; let fallbackHost: String; func run() throws }`. `@MainActor` because it reads `AppModel`'s keys, which are isolated to the main actor. Production caller: `AppModel.live()` (Task 3).
- Produces (tests only): `final class RecordingDefaults: UserDefaults, @unchecked Sendable` with `writes: [String]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PixelClockTilesAppTests/RecordingDefaults.swift
import Foundation

/// Defaults that remember the order keys were written in, so a test can say
/// which write came last.
///
/// Both setters are recorded: `set(true, forKey:)` reaches the `Bool` one,
/// and whether that forwards to the `Any?` one is Foundation's business. A key
/// recorded twice changes nothing about which came last.
final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}
```

```swift
// Tests/PixelClockTilesAppTests/ClockMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

@Test @MainActor func theOldAddressBecomesOneAwtrixClockNamedClock() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    defaults.set("awtrix_a07f9c", forKey: AppModel.deviceUIDKey)

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    let clocks = ClockStore(defaults: defaults).all()
    #expect(clocks.count == 1)
    #expect(clocks.first?.name == "Clock")
    #expect(clocks.first?.model == .awtrix3)
    #expect(clocks.first?.address == "10.0.0.9")
    #expect(clocks.first?.hardwareIdentity == "awtrix_a07f9c")
}

// An installation that never saved an address was talking to the default one,
// so that is the clock it has.
@Test @MainActor func anInstallationThatNeverSavedAnAddressGetsTheOneItWasUsing() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    let clock = try #require(ClockStore(defaults: defaults).all().first)
    #expect(clock.address == AppModel.defaultDeviceHost)
    #expect(clock.hardwareIdentity == nil)
}

@Test @MainActor func theClockMigrationLeavesTheOldKeysAsTheyWere() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    defaults.set("awtrix_a07f9c", forKey: AppModel.deviceUIDKey)

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
    #expect(defaults.string(forKey: AppModel.deviceUIDKey) == "awtrix_a07f9c")
}

// Last, so a run the process did not survive has no marker and runs again.
@Test @MainActor func theClockMigrationWritesItsMarkerLast() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    #expect(defaults.writes.contains(ClockStore.key))
    #expect(defaults.writes.last == ClockMigration.markerKey)
}

// The old key changes between the runs, so a second run that migrated again
// would show.
@Test @MainActor func aSecondClockMigrationChangesNothing() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    let migration = ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost)
    try migration.run()
    let first = defaults.data(forKey: ClockStore.key)
    defaults.set("10.0.0.7", forKey: AppModel.deviceHostKey)

    try migration.run()

    #expect(defaults.data(forKey: ClockStore.key) == first)
}

// A run cut short after the records and before the marker. What it left is
// not trusted: the step starts again from the old keys.
@Test @MainActor func aClockMigrationCutShortStartsAgainFromTheOldKeys() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    try ClockStore(defaults: defaults).replaceAll([
        ClockRecord(name: "Half", model: .ulanziTC002, address: "10.0.0.1"),
    ])

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    let clocks = ClockStore(defaults: defaults).all()
    #expect(clocks.map(\.address) == ["10.0.0.9"])
    #expect(clocks.map(\.name) == ["Clock"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClockMigrationTests`
Expected: FAIL — `cannot find 'ClockMigration' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PixelClockTilesApp/ClockMigration.swift
import Foundation
import PixelClockKit

/// Turns the one address an installation had into its one clock record.
///
/// Runs once: its marker is written after the record, so a run cut short
/// before the marker runs again from the old keys at the next launch rather
/// than trusting half of what it wrote. The old keys are only read, never
/// written or removed.
@MainActor
struct ClockMigration {
    static let markerKey = "migration.clocks"

    let defaults: UserDefaults
    /// What an installation that never saved an address was talking to.
    let fallbackHost: String

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        let clock = ClockRecord(
            name: "Clock",
            model: .awtrix3,
            address: defaults.string(forKey: AppModel.deviceHostKey) ?? fallbackHost,
            hardwareIdentity: defaults.string(forKey: AppModel.deviceUIDKey)
        )
        try ClockStore(defaults: defaults).replaceAll([clock])
        defaults.set(true, forKey: Self.markerKey)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClockMigrationTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutation check**

`git add Sources/PixelClockTilesApp/ClockMigration.swift Tests/PixelClockTilesAppTests/RecordingDefaults.swift Tests/PixelClockTilesAppTests/ClockMigrationTests.swift`, then one site at a time, reverting with `git checkout -- Sources/PixelClockTilesApp/ClockMigration.swift`. The marker guard sits in front of every other line, so the table runs with it in place, top to bottom.

| Site | Mutation | Must fail |
| --- | --- | --- |
| marker guard | delete the `guard` line | `aSecondClockMigrationChangesNothing` |
| marker last | swap the last two lines of `run()` | `theClockMigrationWritesItsMarkerLast` |
| fallback | `?? ""` | `anInstallationThatNeverSavedAnAddressGetsTheOneItWasUsing` |
| identity | `hardwareIdentity: nil` | `theOldAddressBecomesOneAwtrixClockNamedClock` |
| starts from the old keys | after the marker guard insert `guard ClockStore(defaults: defaults).all().isEmpty else { defaults.set(true, forKey: Self.markerKey); return }` | `aClockMigrationCutShortStartsAgainFromTheOldKeys` |
| old keys untouched | insert `defaults.removeObject(forKey: AppModel.deviceHostKey)` before the marker write | `theClockMigrationLeavesTheOldKeysAsTheyWere` |

`try … replaceAll` cannot be mutated into a failure through a test: `ClockRecord` always encodes. The `throws` is there so that the marker line cannot be reached after a failed write. Nothing reaches that path today.

- [ ] **Step 6: Leave staged, no commit** — committed with Task 3.

---

### Task 3: The launch drives the clock in `clocks`

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` — `deviceHostKey`/`deviceUIDKey` docs (≈130–142), new stored properties after `private let device: AwtrixDevice` (≈211), `typedHost` (≈236–238), `init` (≈468–528), `live()` (≈535–631), `followTheClock()` (≈1311–1342)
- Modify: `Sources/PixelClockTilesApp/MenuPanel.swift` — `DeviceHostField.save` (≈99–117)
- Modify: `Sources/PixelClockTilesApp/SettingsSheet.swift` — `deviceHostSection` doc comment (≈81–91)
- Modify: `Tests/PixelClockTilesAppTests/Doubles.swift` — `testModel` (≈451–530), the `AppModel(` call (≈832)
- Modify: `Tests/PixelClockTilesAppTests/AppShellTests.swift` — 7 tests (≈794–915)
- Modify: `Tests/PixelClockTilesAppTests/AppModelTests.swift` — 4 tests (≈1088–1139), the `AppModel(` call (≈1330)
- Modify: `Tests/PixelClockTilesAppTests/DeviceRelocationWiringTests.swift` — 6 tests
- Create: `Tests/PixelClockTilesAppTests/RecordWiringTests.swift`

**Interfaces:**
- Consumes (existing, verified):
  - `static func live(defaults: UserDefaults = .standard, transport: any Transport = URLSessionTransport(), anecdoteStore: URL = AppPaths.anecdoteStore) -> AppModel`
  - `init(deviceHost: String, device: AwtrixDevice, relocate: RelocatingHost? = nil, registry: ConnectorRegistry, host: any ConnectorRunning, store: any SettingsStore, installer: CatalogueIconInstaller, anecdotes: (any AnecdoteReplaying)? = nil, defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general, alerts: any BatteryWarningPresenting, focus: FocusGate, focusGated: [FocusGatedConnector] = [], vpnLamps: VPNLampDisplay? = nil, vpnPresence: VPNPresence = VPNPresence(), quietHours: QuietWindow = .default, microphone: MicrophoneGate, watching: [WatchedMicrophone] = MicrophoneGate.defaultWatchSet, sleep: …, pollSleep: …, micSleep: …)`
  - `private func followTheClock() async`; `typealias RelocatingHost = @MainActor (String?) async -> String?`
  - `@MainActor enum DeviceHostField { static let takesEffectNextLaunch; static let unusable; @discardableResult static func save(_ typed: String, to defaults: UserDefaults) -> String? }`
  - `DeviceAddress.host(from typed: String) -> String?`; `DeviceStats.uid: String`; `AwtrixDevice.init(host: String, transport: Transport)`; `AwtrixDevice.adopt(host:)`
  - Tasks 1–2: `ClockStore`, `ClockRecord`, `ClockMigration`
- Produces: `AppModel.init(clock: ClockRecord, device: …)` in place of `deviceHost:`; `DeviceHostField.save(_ typed: String, to clocks: ClockStore, for clock: ClockRecord) -> String?`; `testModel(…, hardwareIdentity: String? = nil, …)`.

- [ ] **Step 1: Write the failing composition-root tests**

```swift
// Tests/PixelClockTilesAppTests/RecordWiringTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

/// A queue file of its own per launch: `AnecdoteQueue.init` reads whatever
/// file it is handed, and a test has no business opening the user's.
private func scratchStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("records-\(UUID().uuidString).json")
}

// The phase's first claim. The first launch migrates; after that the record
// is what is read, so an address changed on the record is the one the next
// launch talks to.
@Test @MainActor func theLaunchReadsItsClockFromTheClockRecords() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    let clocks = ClockStore(defaults: defaults)
    let clock = try #require(clocks.all().first)
    clocks.update(clock) { $0.address = "10.0.0.7" }

    let relaunched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(relaunched.deviceHost == "10.0.0.7")
}

// Migrated, and then the list is gone — a hand-edited domain, nothing the app
// does. The launch still drives a clock, and stores it, so what the launch
// learns about it has somewhere to go.
@Test @MainActor func aLaunchWithNoClockStoredDrivesTheDefaultOneAndKeepsIt() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: ClockMigration.markerKey)

    let launched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(launched.deviceHost == AppModel.defaultDeviceHost)
    #expect(ClockStore(defaults: defaults).all().map(\.address) == [AppModel.defaultDeviceHost])
}
```

`theDeviceHostIsTakenFromDefaultsWhenOneIsSaved` and `theDeviceHostFallsBackToTheOneOnTheDesk` in `AppShellTests.swift` stay exactly as they are. They set the old key (or not) before `live()`, so from this task on they pin the upgrade path through `ClockMigration`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter RecordWiringTests`
Expected: FAIL — in `theLaunchReadsItsClockFromTheClockRecords` the `#require` on `clocks.all().first` fails, because `live()` still reads `deviceHost` and nothing writes a clock record. In `aLaunchWithNoClockStoredDrivesTheDefaultOneAndKeepsIt` the second expectation fails on an empty store.

- [ ] **Step 3: Move the existing tests' storage reads onto the record**

Everything below is a change to *where* each test reads the stored address or identity. Inputs, the rules asserted and the comments above each test stay byte-identical. The old key is no longer written by anything, so leaving these reads in place would make every one of these tests vacuous.

`Tests/PixelClockTilesAppTests/Doubles.swift` — in `testModel`'s parameter list, after `deviceHost: String = "10.0.0.5",` add:

```swift
    // Nil, as a clock that has never answered: a test that needs the model to
    // remember which clock is its own says so.
    hardwareIdentity: String? = nil,
```

and in its body replace `deviceHost: deviceHost,` inside `return AppModel(` with:

```swift
        clock: ClockRecord(
            name: "Clock", model: .awtrix3, address: deviceHost, hardwareIdentity: hardwareIdentity
        ),
```

In the second `AppModel(` call in the same file (≈832) and in `AppModelTests.swift` (≈1330), replace `deviceHost: "10.0.0.5",` with:

```swift
        clock: ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5"),
```

`testModel` does not seed the store. `ClockStore.update` inserts when nothing is stored, so "nothing was written" stays observable as an empty store.

`Tests/PixelClockTilesAppTests/DeviceRelocationWiringTests.swift`:

```swift
// theClockThatAnswersIsRememberedByTheNameItGivesItself — replace the
// deviceUIDKey expectation with:
    #expect(ClockStore(defaults: defaults).all().first?.hardwareIdentity == "abc")

// aClockThatStoppedAnsweringIsLookedForAndMovedOnto — delete
// `defaults.set("awtrix_a07f9c", forKey: AppModel.deviceUIDKey)` and pass the
// identity to the model instead:
    let subject = testModel(
        transport: unreachable(), defaults: defaults, pollSleep: poll.sleep,
        hardwareIdentity: "awtrix_a07f9c", relocate: relocation.relocate
    )

// theAddressTheAppMovedOntoIsWrittenDownForNextTime — replace the
// deviceHostKey expectation with:
    #expect(ClockStore(defaults: defaults).all().first?.address == "awtrix_a07f9c.local")

// anAnswerThatIsTheAddressAlreadyInUseChangesNothing and
// findingNothingLeavesTheAddressAlone — replace the deviceHostKey expectation with:
    #expect(ClockStore(defaults: defaults).all().isEmpty)
```

`Tests/PixelClockTilesAppTests/AppModelTests.swift`:

```swift
// theAddressSavesAsItIsTypedWithNothingToPress:
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")

// everyChangeIsSavedRatherThanOnlyTheLast — the two expectations become:
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0")
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")

// seedingTheFieldSavesNothing:
    #expect(ClockStore(defaults: defaults).all().isEmpty)

// clearingTheFieldSavesNothingAndClaimsNothing:
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
```

`Tests/PixelClockTilesAppTests/AppShellTests.swift`:

`aDiscoveredInstanceIsNeverWrittenAsTheAddressTheAppTalksTo` has been vacuous since it was written. It reads `defaults`, but the model under test was built over a suite of its own, so nothing the model did could ever show up in what it read. The model now gets the test's suite:

```swift
        model: testModel(defaults: defaults, sleep: Metronome().sleep, pollSleep: Metronome().sleep),
```

and the expectation on `AppModel.deviceHostKey` becomes:

```swift
    #expect(ClockStore(defaults: defaults).all().contains { $0.address == "awtrix_a07f9c" } == false)
```

The six `DeviceHostField` tests under `// MARK: - The address the next launch will use`, bodies only:

```swift
@Test @MainActor func theAddressTypedIntoThePanelIsWhatTheNextLaunchUses() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // A launch first: the field exists only on a running app, and it is the
    // launch that migrates. A field still writing the old key would pass on a
    // domain nothing had launched on yet.
    _ = AppModel.live(defaults: defaults, anecdoteStore: scratchStore())
    let clocks = ClockStore(defaults: defaults)
    let clock = try #require(clocks.all().first)

    DeviceHostField.save("10.0.0.9", to: clocks, for: clock)

    // Read back the way the app reads it, not the way it was written: a field
    // writing some other key would save happily and change nothing.
    #expect(AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.9")
}

@Test @MainActor func aBlankAddressIsRefusedRatherThanSaved() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clocks = ClockStore(defaults: defaults)
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.9")
    try clocks.replaceAll([clock])

    #expect(DeviceHostField.save("   \n ", to: clocks, for: clock) == nil)

    // And the address that was there is still there.
    #expect(clocks.all().first?.address == "10.0.0.9")
}

@Test @MainActor func theAddressIsTrimmedBeforeItIsSaved() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clocks = ClockStore(defaults: defaults)

    DeviceHostField.save(
        "  192.168.1.72\n", to: clocks,
        for: ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    )

    #expect(clocks.all().first?.address == "192.168.1.72")
}

@Test @MainActor func aPastedAddressIsStoredWithoutItsScheme() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = AppModel.live(defaults: defaults, anecdoteStore: scratchStore())
    let clocks = ClockStore(defaults: defaults)
    let clock = try #require(clocks.all().first)

    let note = DeviceHostField.save("http://10.0.0.5/", to: clocks, for: clock)

    #expect(note == DeviceHostField.takesEffectNextLaunch)
    #expect(clocks.all().first?.address == "10.0.0.5")
    #expect(
        AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.5"
    )
}

@Test @MainActor func anAddressThatCannotBeAHostIsRefusedOnTheField() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clocks = ClockStore(defaults: defaults)
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.9")
    try clocks.replaceAll([clock])

    #expect(DeviceHostField.save("a b", to: clocks, for: clock) == DeviceHostField.unusable)
    #expect(DeviceHostField.save("http://", to: clocks, for: clock) == DeviceHostField.unusable)

    // And the address that was there is still there.
    #expect(clocks.all().first?.address == "10.0.0.9")
}

@Test @MainActor func savingSaysItTakesEffectAtTheNextLaunchRatherThanNow() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let note = DeviceHostField.save(
        "10.0.0.9", to: ClockStore(defaults: defaults),
        for: ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    )

    #expect(note == DeviceHostField.takesEffectNextLaunch)
    #expect(note?.lowercased().contains("next launch") == true)
}
```

Replace only the setup and read-back lines in each; keep each test's comment block as it is.

- [ ] **Step 4: Run to verify the target no longer compiles against the old signatures**

Run: `swift build --build-tests`
Expected: FAIL — `extra argument 'clock' in call` / `incorrect argument label` on `AppModel(` and `DeviceHostField.save(`.

- [ ] **Step 5: Implement — `AppModel.swift`**

Replace the two key declarations and their docs (≈130–142):

```swift
    /// Where an installation from before the clock records kept the address.
    /// `ClockMigration` reads it once; nothing writes it any more.
    static let deviceHostKey = "deviceHost"
    /// What a launch with no address of its own talks to.
    static let defaultDeviceHost = "192.168.1.72"
    /// Where an installation from before the clock records kept the clock's
    /// name for itself, as `/api/stats` gives it. `ClockMigration` reads it
    /// once into `ClockRecord.hardwareIdentity`, which is what relocation asks
    /// for now — the one thing that tells OUR clock from a neighbour's.
    static let deviceUIDKey = "deviceUID"
```

After `private let device: AwtrixDevice` add:

```swift
    /// The clock this model drives: as it was stored at launch, plus what this
    /// launch has since learned about it. Its id is what every write below is
    /// keyed by.
    private var clock: ClockRecord
    /// Where what is learned about the clock is written down for the next
    /// launch.
    private let clocks: ClockStore
```

`typedHost`'s observer:

```swift
    @Published var typedHost: String {
        didSet { hostNote = DeviceHostField.save(typedHost, to: clocks, for: clock) }
    }
```

In `init`, the first parameter `deviceHost: String,` becomes `clock: ClockRecord,`, and the first two lines of the body

```swift
        self.deviceHost = deviceHost
        self.typedHost = deviceHost
```

become

```swift
        self.clock = clock
        self.clocks = ClockStore(defaults: defaults)
        self.deviceHost = clock.address
        self.typedHost = clock.address
```

In `live()`, replace

```swift
        let deviceHost = defaults.string(forKey: deviceHostKey) ?? defaultDeviceHost
        let device = AwtrixDevice(host: deviceHost, transport: transport)
```

with

```swift
        // Before anything reads a record. A step that fails leaves its marker
        // unwritten and runs again at the next launch; this launch drives
        // whatever is stored, and the line below makes sure something is.
        try? ClockMigration(defaults: defaults, fallbackHost: defaultDeviceHost).run()
        let clock = ClockStore(defaults: defaults).firstClock(orCreatingAt: defaultDeviceHost)
        let device = AwtrixDevice(host: clock.address, transport: transport)
```

and in its `return AppModel(` replace `deviceHost: deviceHost,` with `clock: clock,`.

Replace `followTheClock()` whole:

```swift
    private func followTheClock() async {
        if case let .online(stats) = monitor.state {
            unansweredPolls = 0
            clock.hardwareIdentity = stats.uid
            clocks.update(clock) { $0.hardwareIdentity = stats.uid }
            return
        }
        unansweredPolls += 1
        guard let relocate,
              RelocationSchedule.isDue(afterConsecutiveFailures: unansweredPolls)
        else { return }
        // The count is NOT reset by a successful move, only by a clock that
        // answers. A move onto the wrong address would otherwise reset the
        // rationing and browse again on the very next poll, and again after
        // that — the browse storm this schedule exists to prevent, rebuilt out
        // of an optimistic reset.
        guard let found = await relocate(clock.hardwareIdentity),
              found != deviceHost
        else { return }

        // The device first: it is the actor the monitor, the custody and every
        // connector hold, so this is the line that actually moves the app. The
        // rest is bookkeeping about a move that has already happened.
        await device.adopt(host: found)
        deviceHost = found
        clock.address = found
        clocks.update(clock) { $0.address = found }
        typedHost = found
        // `typedHost` has a `didSet` that saves and then says so, and what it
        // says is "Saved — takes effect at next launch". Both halves are wrong
        // here: nobody typed, and it took effect at once. The note is what a
        // person's own editing earns.
        hostNote = nil
    }
```

The doc comment above `followTheClock()` stays as it is.

- [ ] **Step 6: Implement — `MenuPanel.swift` and `SettingsSheet.swift`**

Replace `DeviceHostField.save` (its doc comment stays, except the first line becomes `/// Stores a typed address on the clock record for the next launch, and answers what to say.`):

```swift
    @discardableResult
    static func save(_ typed: String, to clocks: ClockStore, for clock: ClockRecord) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let host = DeviceAddress.host(from: trimmed) else { return unusable }
        clocks.update(clock) { $0.address = host }
        return takesEffectNextLaunch
    }
```

In `SettingsSheet.deviceHostSection`'s doc comment, replace `same \`UserDefaults\` key \`AppModel.live()\` reads at launch` with `address on the clock record \`AppModel.live()\` reads at launch`.

- [ ] **Step 7: Run to verify everything passes**

Run: `swift test --filter 'ClockStoreTests|ClockMigrationTests|RecordWiringTests|DeviceRelocationWiringTests|AppShellTests|AppModelTests'`
Expected: PASS.
Then: `swift test`
Expected: PASS for the whole suite (see Global Constraints about the four wall-clock tests under load).

- [ ] **Step 8: Mutation check**

`git add` every file listed for this task, then one site at a time, reverting each with `git checkout -- <file>`:

| Site | Mutation | Must fail |
| --- | --- | --- |
| `live()` reads the record | `let device = AwtrixDevice(host: defaults.string(forKey: deviceHostKey) ?? defaultDeviceHost, transport: transport)` | `theLaunchReadsItsClockFromTheClockRecords` |
| `live()` runs the migration | delete the `ClockMigration` line | `theDeviceHostIsTakenFromDefaultsWhenOneIsSaved` |
| `live()` stores its fallback | `let clock = ClockStore(defaults: defaults).all().first ?? ClockRecord(name: "Clock", model: .awtrix3, address: defaultDeviceHost)` | `aLaunchWithNoClockStoredDrivesTheDefaultOneAndKeepsIt` |
| identity written | delete `clocks.update(clock) { $0.hardwareIdentity = stats.uid }` | `theClockThatAnswersIsRememberedByTheNameItGivesItself` |
| identity remembered | `relocate(nil)` | `aClockThatStoppedAnsweringIsLookedForAndMovedOnto` |
| `found != deviceHost` (existing guard; re-run because its assertion moved) | delete `, found != deviceHost` | `anAnswerThatIsTheAddressAlreadyInUseChangesNothing` |
| field writes the record | `clocks.update(clock) { _ in }` in `DeviceHostField.save` | `theAddressIsTrimmedBeforeItIsSaved`, `theAddressTypedIntoThePanelIsWhatTheNextLaunchUses` |
| blank guard (existing; re-run) | delete `guard trimmed.isEmpty == false else { return nil }` | `aBlankAddressIsRefusedRatherThanSaved` |
| init writes nothing | append `clocks.update(clock) { _ in }` to `AppModel.init` | `seedingTheFieldSavesNothing` |

One site is expected to survive: deleting `clocks.update(clock) { $0.address = found }` in `followTheClock()`. `typedHost = found` right after it writes the same address through `DeviceHostField.save`. Today's code has the same double write (`defaults.set` next to the field's own save), and it is kept for parity. The explicit write does not depend on a UI property's observer.

- [ ] **Step 9: Commit**

```bash
git add Sources/PixelClockKit/Clocks \
  Sources/PixelClockTilesApp/ClockMigration.swift Sources/PixelClockTilesApp/AppModel.swift \
  Sources/PixelClockTilesApp/MenuPanel.swift Sources/PixelClockTilesApp/SettingsSheet.swift \
  Tests/PixelClockKitTests/ClockStoreTests.swift \
  Tests/PixelClockTilesAppTests/RecordingDefaults.swift Tests/PixelClockTilesAppTests/ClockMigrationTests.swift \
  Tests/PixelClockTilesAppTests/RecordWiringTests.swift Tests/PixelClockTilesAppTests/Doubles.swift \
  Tests/PixelClockTilesAppTests/AppShellTests.swift Tests/PixelClockTilesAppTests/AppModelTests.swift \
  Tests/PixelClockTilesAppTests/DeviceRelocationWiringTests.swift
git commit -m "feat: drive the clock in the clock records, migrated from the old address

The record, its store, the migration step and the reader land together:
the launch cannot read clocks without the step that fills them, and the
step must not land ahead of a reader. deviceHost and deviceUID are read
once and never written again."
```

---

### Task 4: The tile record and its store

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TileRecord.swift`
- Create: `Sources/PixelClockKit/Tiles/TileStore.swift`
- Test: `Tests/PixelClockKitTests/TileStoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `public struct TileKey: Codable, Sendable, Hashable` — `clockId: UUID`, `connectorId: String`, `instance: String`; `init(clockId: UUID, connectorId: String, instance: String = "")`
  - `public struct TilePolicyRecord: Codable, Sendable, Equatable` — `isPaused: Bool`, `refreshSeconds: Int`; `init(isPaused:refreshSeconds:)`
  - `public struct TileRecord: Codable, Sendable, Equatable` — `key: TileKey` (let), `policy: TilePolicyRecord`, `lastDeliveredAt: Date?`; `init(key:policy:lastDeliveredAt: Date? = nil)`
  - `public final class TileStore: @unchecked Sendable` — `static let key = "tiles"`, `init(defaults: UserDefaults = .standard)`, `func all() -> [TileRecord]`, `func replaceAll(_ tiles: [TileRecord]) throws`, `func update(_ tile: TileRecord, _ change: (inout TileRecord) -> Void)`
- Production callers: `TileSettingsStore` (Task 5: `all`, `update`), `TileMigration.run()` (Task 6: `replaceAll`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PixelClockKitTests/TileStoreTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private let desk = UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11")!
private let kitchen = UUID(uuidString: "0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D")!

private func tile(
    on clock: UUID = desk, _ connector: String, paused: Bool = false, every seconds: Int = 600
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: seconds)
    )
}

// Written out rather than encoded by the code under test, for the reason the
// clocks' shape test gives. Phase 4 extends `policy` with keys of its own and
// has to decode exactly this.
@Test func tilesAreReadFromTheShapeTheyAreStoredIn() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
        Data(
            #"""
            [{"key":{"clockId":"6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11","connectorId":"weather",\#
            "instance":""},"policy":{"isPaused":true,"refreshSeconds":600},\#
            "lastDeliveredAt":777000000},\#
            {"key":{"clockId":"6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11","connectorId":"claude",\#
            "instance":""},"policy":{"isPaused":false,"refreshSeconds":300}}]
            """#.utf8
        ),
        forKey: "tiles"
    )

    #expect(
        TileStore(defaults: defaults).all() == [
            TileRecord(
                key: TileKey(clockId: desk, connectorId: "weather"),
                policy: TilePolicyRecord(isPaused: true, refreshSeconds: 600),
                lastDeliveredAt: Date(timeIntervalSinceReferenceDate: 777_000_000)
            ),
            TileRecord(
                key: TileKey(clockId: desk, connectorId: "claude"),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 300)
            ),
        ]
    )
}

@Test func aKeyThatDoesNotDecodeReadsAsNoTiles() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not tiles".utf8), forKey: TileStore.key)

    #expect(TileStore(defaults: defaults).all().isEmpty)
}

@Test func replacedTilesSurviveARelaunchInOrder() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = [tile("anecdotes", every: 1800), tile("weather"), tile("claude", every: 300)]

    try TileStore(defaults: defaults).replaceAll(tiles)

    #expect(TileStore(defaults: defaults).all() == tiles)
}

// The key is the clock AND the connector. The same connector on two clocks is
// two tiles, and a change to one is not a change to the other.
@Test func anUpdateChangesOnlyTheTileWithThatKey() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TileStore(defaults: defaults)
    let onDesk = tile(on: desk, "weather")
    let inKitchen = tile(on: kitchen, "weather")
    try store.replaceAll([onDesk, inKitchen])

    store.update(inKitchen) { $0.policy.isPaused = true }

    #expect(store.all().first == onDesk)
    #expect(store.all().last?.policy.isPaused == true)
}

// Applied to what is stored, not to the template: a caller that only knows
// some of a tile's fields must not write its guesses over the others.
@Test func anUpdateLandsOnTheStoredTileRatherThanOnTheTemplate() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TileStore(defaults: defaults)
    try store.replaceAll([tile("weather", every: 700)])
    let delivered = Date(timeIntervalSinceReferenceDate: 777_000_000)

    store.update(tile("weather", every: 300)) { $0.lastDeliveredAt = delivered }

    #expect(store.all().first?.policy.refreshSeconds == 700)
    #expect(store.all().first?.lastDeliveredAt == delivered)
}

@Test func anUpdateStoresATileThatWasNotStoredYet() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TileStore(defaults: defaults)

    store.update(tile("claude", every: 300)) { $0.policy.isPaused = true }

    #expect(store.all() == [tile("claude", paused: true, every: 300)])
}

@Test func concurrentUpdatesThroughTwoTileStoresAreNeverLost() async throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = TileStore(defaults: defaults)
    let second = TileStore(defaults: defaults)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            let store = index.isMultiple(of: 2) ? first : second
            let added = tile("connector-\(index)")
            group.addTask { store.update(added) { _ in } }
        }
    }

    #expect(first.all().count == 16)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TileStoreTests`
Expected: FAIL — `cannot find 'TileRecord' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PixelClockKit/Tiles/TileRecord.swift
import Foundation

/// One connector on one clock, which is what a tile is.
public struct TileKey: Codable, Sendable, Hashable {
    public let clockId: UUID
    public let connectorId: String
    /// Empty for a connector that sits on a clock once; the watched key for
    /// one that sits there once per key. Empty rather than optional, so a
    /// second tile of a single connector on one clock would have the first
    /// one's key.
    public let instance: String

    public init(clockId: UUID, connectorId: String, instance: String = "") {
        self.clockId = clockId
        self.connectorId = connectorId
        self.instance = instance
    }
}

/// The stored half of a tile's policy — the part the schedule reads today.
///
/// A record, not the policy: what a tile's policy decides is `TilePolicy`'s
/// to say. Phase 4 adds the Focus and the hours here, as optional keys.
public struct TilePolicyRecord: Codable, Sendable, Equatable {
    public var isPaused: Bool
    /// Seconds between runs. Seconds rather than a position on the slider's
    /// scale, so the scale can gain steps without moving what is stored.
    public var refreshSeconds: Int

    public init(isPaused: Bool, refreshSeconds: Int) {
        self.isPaused = isPaused
        self.refreshSeconds = refreshSeconds
    }
}

public struct TileRecord: Codable, Sendable, Equatable {
    public let key: TileKey
    public var policy: TilePolicyRecord
    /// When this tile last put something on its clock, or nil while it never
    /// has. The cadence is measured from it across launches.
    public var lastDeliveredAt: Date?

    public init(key: TileKey, policy: TilePolicyRecord, lastDeliveredAt: Date? = nil) {
        self.key = key
        self.policy = policy
        self.lastDeliveredAt = lastDeliveredAt
    }
}
```

```swift
// Sources/PixelClockKit/Tiles/TileStore.swift
import Foundation

/// The tiles of every clock, as one JSON array under one `UserDefaults` key.
public final class TileStore: @unchecked Sendable {
    public static let key = "tiles"

    /// Static, for the reason `ClockStore`'s is.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// In stored order. A key that does not decode reads as no tiles.
    public func all() -> [TileRecord] {
        Self.lock.withLock { stored() }
    }

    /// Replaces every tile. Throws for the reason `ClockStore.replaceAll`
    /// does.
    public func replaceAll(_ tiles: [TileRecord]) throws {
        let data = try JSONEncoder().encode(tiles)
        Self.lock.withLock { defaults.set(data, forKey: Self.key) }
    }

    /// Applies `change` to the stored tile with `tile`'s key, or stores
    /// `tile` with the change applied when there is none. The change lands on
    /// what is stored, so fields the caller does not know about survive it.
    public func update(_ tile: TileRecord, _ change: (inout TileRecord) -> Void) {
        Self.lock.withLock {
            var tiles = stored()
            if let index = tiles.firstIndex(where: { $0.key == tile.key }) {
                change(&tiles[index])
            } else {
                var inserted = tile
                change(&inserted)
                tiles.append(inserted)
            }
            guard let data = try? JSONEncoder().encode(tiles) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    private func stored() -> [TileRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([TileRecord].self, from: data)) ?? []
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TileStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Mutation check**

`git add Sources/PixelClockKit/Tiles Tests/PixelClockKitTests/TileStoreTests.swift`, then one site at a time, reverting with `git checkout -- <file>`:

| Site | Mutation | Must fail |
| --- | --- | --- |
| key match | `$0.key.connectorId == tile.key.connectorId` | `anUpdateChangesOnlyTheTileWithThatKey` |
| found branch | `var copy = tile; change(&copy); tiles[index] = copy` | `anUpdateLandsOnTheStoredTileRatherThanOnTheTemplate` |
| insert branch | empty the `else` body | `anUpdateStoresATileThatWasNotStoredYet` |
| the lock | per-instance `lock`, used in `update` | `concurrentUpdatesThroughTwoTileStoresAreNeverLost` (three runs) |
| stored shape | add `enum CodingKeys: String, CodingKey { case isPaused, refreshSeconds = "refresh" }` to `TilePolicyRecord` | `tilesAreReadFromTheShapeTheyAreStoredIn` |

- [ ] **Step 6: Leave staged, no commit** — committed with Task 7.

---

### Task 5: One clock's tiles, served as its connector settings

**Files:**
- Create: `Sources/PixelClockKit/Tiles/TileSettingsStore.swift`
- Test: `Tests/PixelClockKitTests/TileSettingsStoreTests.swift`

**Interfaces:**
- Consumes (existing, verified):
  - `public protocol SettingsStore: Sendable { func storedSettings(for id: String) -> ConnectorSettings?; func save(_ settings: ConnectorSettings, for id: String) }`
  - `public struct ConnectorSettings: Sendable, Codable, Equatable` — `isEnabled: Bool`, `intervalPosition: Int`, `lastDeliveredAt: Date?`, `init(isEnabled: Bool = true, intervalPosition: Int = 5, lastDeliveredAt: Date? = nil)`, `var interval: TimeInterval` (= `IntervalScale.duration(atPosition: intervalPosition)`)
  - `IntervalScale.position(for duration: TimeInterval) -> Int`, `IntervalScale.duration(atPosition:) -> TimeInterval`
  - Task 4: `TileStore`, `TileRecord`, `TileKey`, `TilePolicyRecord`
- Produces: `public final class TileSettingsStore: SettingsStore, @unchecked Sendable` — `init(defaults: UserDefaults, clockId: UUID)`. Production caller: `AppModel.live()` (Task 7), which hands the same instance to `ConnectorHost(store:)` and `AppModel(store:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PixelClockKitTests/TileSettingsStoreTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private let desk = UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11")!
private let kitchen = UUID(uuidString: "0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D")!
private let delivered = Date(timeIntervalSinceReferenceDate: 777_000_000)

private func stored(
    on clock: UUID = desk, _ connector: String, paused: Bool = false, every seconds: Int,
    deliveredAt: Date? = nil
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: seconds),
        lastDeliveredAt: deliveredAt
    )
}

// The nil `AppModel.resolved` turns into the connector's OWN default. A store
// that answered with `ConnectorSettings()` here would reschedule a five-minute
// connector to thirty, which is what `storedSettings` exists to prevent.
@Test func aConnectorWithNoTileOnTheClockHasNoStoredSettings() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "weather") == nil)
}

@Test func aTileOnAnotherClockIsNotThisClocksSettings() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([stored(on: kitchen, "weather", every: 600)])

    #expect(TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "weather") == nil)
}

@Test func aTileReadsAsTheSettingsTheScheduleAlreadyUnderstands() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([
        stored("anecdotes", paused: true, every: 3600, deliveredAt: delivered),
    ])

    #expect(
        TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "anecdotes")
            == ConnectorSettings(isEnabled: false, intervalPosition: 11, lastDeliveredAt: delivered)
    )
}

// Seconds the slider has no step for read as the nearest step it has. 700 s is
// nearer ten minutes than fifteen; 30 s is below the slider's floor.
@Test func secondsBetweenStepsReadAsTheNearestStep() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([
        stored("weather", every: 700), stored("claude", every: 30),
    ])
    let store = TileSettingsStore(defaults: defaults, clockId: desk)

    #expect(store.storedSettings(for: "weather")?.intervalPosition == 1)
    #expect(store.storedSettings(for: "claude")?.intervalPosition == 0)
}

@Test func savingWritesTheChoiceIntoTheTile() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([stored("anecdotes", every: 1800)])

    TileSettingsStore(defaults: defaults, clockId: desk).save(
        ConnectorSettings(isEnabled: false, intervalPosition: 11, lastDeliveredAt: delivered),
        for: "anecdotes"
    )

    #expect(
        TileStore(defaults: defaults).all()
            == [stored("anecdotes", paused: true, every: 3600, deliveredAt: delivered)]
    )
}

// A connector registered after the migration ran has no tile, and its first
// saved choice is what gives it one.
@Test func savingGivesAConnectorWithNoTileOne() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    TileSettingsStore(defaults: defaults, clockId: desk).save(
        ConnectorSettings(isEnabled: true, intervalPosition: 0), for: "claude"
    )

    #expect(TileStore(defaults: defaults).all() == [stored("claude", every: 300)])
}

// Every delivery saves the whole settings value back, and the position in it
// is a snapped reading of the seconds. Written back, the snap would turn 700 s
// into 600 s one delivery after it was set — and in Phase 4 a 30 s refresh
// into five minutes.
@Test func aDeliveryDoesNotRoundTheRefreshOntoTheScale() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([stored("weather", every: 700)])
    let store = TileSettingsStore(defaults: defaults, clockId: desk)
    var settings = try #require(store.storedSettings(for: "weather"))

    settings.lastDeliveredAt = delivered
    store.save(settings, for: "weather")

    #expect(TileStore(defaults: defaults).all().first?.policy.refreshSeconds == 700)
    #expect(TileStore(defaults: defaults).all().first?.lastDeliveredAt == delivered)
}

@Test func aChoiceSurvivesARelaunch() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let chosen = ConnectorSettings(isEnabled: false, intervalPosition: 3, lastDeliveredAt: delivered)

    TileSettingsStore(defaults: defaults, clockId: desk).save(chosen, for: "anecdotes")

    #expect(
        TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "anecdotes")
            == chosen
    )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TileSettingsStoreTests`
Expected: FAIL — `cannot find 'TileSettingsStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PixelClockKit/Tiles/TileSettingsStore.swift
import Foundation

/// One clock's tiles, in the shape the schedule and the host already read.
///
/// The seam that lets tiles replace `connector.<id>` without either reader
/// changing: `ConnectorHost` and `AppModel` ask a `SettingsStore`, and this
/// one answers from the tiles on the clock the app drives.
public final class TileSettingsStore: SettingsStore, @unchecked Sendable {
    private let tiles: TileStore
    private let clockId: UUID

    public init(defaults: UserDefaults, clockId: UUID) {
        self.tiles = TileStore(defaults: defaults)
        self.clockId = clockId
    }

    /// Nil when the clock carries no tile for this connector, which is what
    /// sends `AppModel` to the connector's own default.
    public func storedSettings(for id: String) -> ConnectorSettings? {
        let key = TileKey(clockId: clockId, connectorId: id)
        guard let tile = tiles.all().first(where: { $0.key == key }) else { return nil }
        return ConnectorSettings(
            isEnabled: !tile.policy.isPaused,
            intervalPosition: IntervalScale.position(
                for: TimeInterval(tile.policy.refreshSeconds)
            ),
            lastDeliveredAt: tile.lastDeliveredAt
        )
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        let seconds = Int(settings.interval)
        let fresh = TileRecord(
            key: TileKey(clockId: clockId, connectorId: id),
            policy: TilePolicyRecord(isPaused: !settings.isEnabled, refreshSeconds: seconds)
        )
        tiles.update(fresh) { tile in
            tile.policy.isPaused = !settings.isEnabled
            // Rewritten only when the slider moved. Every delivery saves
            // too, and the position is a snapped reading of the seconds:
            // writing the snap back would turn a refresh the scale cannot
            // show into the nearest one it can, one delivery after it was set.
            let shown = IntervalScale.position(for: TimeInterval(tile.policy.refreshSeconds))
            if shown != settings.intervalPosition {
                tile.policy.refreshSeconds = seconds
            }
            tile.lastDeliveredAt = settings.lastDeliveredAt
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'TileSettingsStoreTests|TileStoreTests'`
Expected: PASS, 15 tests.

- [ ] **Step 5: Mutation check**

`git add Sources/PixelClockKit/Tiles/TileSettingsStore.swift Tests/PixelClockKitTests/TileSettingsStoreTests.swift`, then one site at a time, reverting with `git checkout -- Sources/PixelClockKit/Tiles/TileSettingsStore.swift`. The snap guard sits in front of the rewrite, so the rewrite's mutation is run with the guard in place (HANDOFF's re-run rule):

| Site | Mutation | Must fail |
| --- | --- | --- |
| absent tile | `else { return ConnectorSettings() }` | `aConnectorWithNoTileOnTheClockHasNoStoredSettings` |
| clock in the key | `first(where: { $0.key.connectorId == id })` | `aTileOnAnotherClockIsNotThisClocksSettings` |
| pause read | `isEnabled: tile.policy.isPaused` | `aTileReadsAsTheSettingsTheScheduleAlreadyUnderstands` |
| pause written | delete `tile.policy.isPaused = !settings.isEnabled` | `savingWritesTheChoiceIntoTheTile` |
| snap guard | `if true \|\| shown != settings.intervalPosition` | `aDeliveryDoesNotRoundTheRefreshOntoTheScale` |
| slider moved | empty the `if` body | `savingWritesTheChoiceIntoTheTile` |
| last delivery | delete `tile.lastDeliveredAt = settings.lastDeliveredAt` | `savingWritesTheChoiceIntoTheTile`, `aDeliveryDoesNotRoundTheRefreshOntoTheScale` |
| insert | `refreshSeconds: 0` in `fresh` | `savingGivesAConnectorWithNoTileOne` |

- [ ] **Step 6: Leave staged, no commit** — committed with Task 7.

---

### Task 6: The tile migration step

**Files:**
- Create: `Sources/PixelClockTilesApp/TileMigration.swift`
- Test: `Tests/PixelClockTilesAppTests/TileMigrationTests.swift`

**Interfaces:**
- Consumes (existing, verified): `UserDefaultsSettingsStore(defaults:)` and its `storedSettings(for:) -> ConnectorSettings?` (key `connector.<id>`; a key that does not decode reads as nil); `ConnectorSettings.interval`; Task 4's `TileStore.replaceAll(_:)`, `TileStore.key`; Task 2's `RecordingDefaults`.
- Produces: `struct TileMigration { static let markerKey = "migration.tiles"; let defaults: UserDefaults; let clockId: UUID; let connectors: [(id: String, defaultInterval: TimeInterval)]; func run() throws }`. Production caller: `AppModel.live()` (Task 7).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PixelClockTilesAppTests/TileMigrationTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let clock = UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11")!
private let delivered = Date(timeIntervalSinceReferenceDate: 777_000_000)

/// What `AppModel.live()` registers, in its order and with its defaults.
private let shipped: [(id: String, defaultInterval: TimeInterval)] = [
    (id: "anecdotes", defaultInterval: 1800),
    (id: "weather", defaultInterval: 600),
    (id: "claude", defaultInterval: 300),
]

/// Writes a connector's settings the way every build before tiles did.
private func saveTheOldWay(_ settings: ConnectorSettings, for id: String, in defaults: UserDefaults) {
    UserDefaultsSettingsStore(defaults: defaults).save(settings, for: id)
}

private func tile(
    _ connector: String, paused: Bool = false, every seconds: Int, deliveredAt: Date? = nil
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: seconds),
        lastDeliveredAt: deliveredAt
    )
}

// Index → duration → seconds, the switch inverted into a pause, the last
// delivery kept — and a connector nobody configured gets its own defaults,
// because it was running on the one clock all along.
@Test func everyConnectorBecomesATileOnTheClockInRegistrationOrder() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    saveTheOldWay(
        ConnectorSettings(isEnabled: false, intervalPosition: 11, lastDeliveredAt: delivered),
        for: "anecdotes", in: defaults
    )

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(
        TileStore(defaults: defaults).all() == [
            tile("anecdotes", paused: true, every: 3600, deliveredAt: delivered),
            tile("weather", every: 600),
            tile("claude", every: 300),
        ]
    )
}

@Test func anOldKeyThatDoesNotDecodeIsANeverConfiguredConnector() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not settings".utf8), forKey: "connector.weather")

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(TileStore(defaults: defaults).all().dropFirst().first == tile("weather", every: 600))
}

@Test func aPositionPastTheEndOfTheScaleBecomesTheLongestRefresh() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    saveTheOldWay(ConnectorSettings(intervalPosition: 99), for: "claude", in: defaults)

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(TileStore(defaults: defaults).all().last?.policy.refreshSeconds == 12 * 3600)
}

@Test func theTileMigrationLeavesTheOldKeysAsTheyWere() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    saveTheOldWay(ConnectorSettings(isEnabled: false, intervalPosition: 11), for: "anecdotes", in: defaults)
    let before = defaults.data(forKey: "connector.anecdotes")

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(defaults.data(forKey: "connector.anecdotes") == before)
    #expect(defaults.data(forKey: "connector.weather") == nil)
}

@Test func theTileMigrationWritesItsMarkerLast() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(defaults.writes.contains(TileStore.key))
    #expect(defaults.writes.last == TileMigration.markerKey)
}

@Test func aSecondTileMigrationChangesNothing() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let migration = TileMigration(defaults: defaults, clockId: clock, connectors: shipped)
    try migration.run()
    let first = defaults.data(forKey: TileStore.key)
    saveTheOldWay(ConnectorSettings(isEnabled: false, intervalPosition: 11), for: "weather", in: defaults)

    try migration.run()

    #expect(defaults.data(forKey: TileStore.key) == first)
}

@Test func aTileMigrationCutShortStartsAgainFromTheOldKeys() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([tile("weather", paused: true, every: 60)])

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(TileStore(defaults: defaults).all().map(\.policy.refreshSeconds) == [1800, 600, 300])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TileMigrationTests`
Expected: FAIL — `cannot find 'TileMigration' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PixelClockTilesApp/TileMigration.swift
import Foundation
import PixelClockKit

/// Turns each connector's `connector.<id>` settings into its tile on the clock
/// the app drives.
///
/// Runs once, marker last, old keys only read — the same terms as
/// `ClockMigration`. A connector with no stored settings gets a tile from its
/// own defaults, because before tiles every registered connector ran on the
/// one clock whether or not anybody had touched its switch.
struct TileMigration {
    static let markerKey = "migration.tiles"

    let defaults: UserDefaults
    let clockId: UUID
    /// In registration order, which is the order the tiles are stored in.
    let connectors: [(id: String, defaultInterval: TimeInterval)]

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        // Read through the store that wrote them, so a key that does not
        // decode means what it has always meant: never configured.
        let legacy = UserDefaultsSettingsStore(defaults: defaults)
        let tiles = connectors.map { connector in
            let chosen = legacy.storedSettings(for: connector.id)
            return TileRecord(
                key: TileKey(clockId: clockId, connectorId: connector.id),
                policy: TilePolicyRecord(
                    isPaused: chosen.map { $0.isEnabled == false } ?? false,
                    // Position to duration to seconds. `interval` clamps a
                    // position past either end of the scale onto it.
                    refreshSeconds: Int(chosen?.interval ?? connector.defaultInterval)
                ),
                lastDeliveredAt: chosen?.lastDeliveredAt
            )
        }
        try TileStore(defaults: defaults).replaceAll(tiles)
        defaults.set(true, forKey: Self.markerKey)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TileMigrationTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Mutation check**

`git add Sources/PixelClockTilesApp/TileMigration.swift Tests/PixelClockTilesAppTests/TileMigrationTests.swift`, then one site at a time, reverting with `git checkout -- Sources/PixelClockTilesApp/TileMigration.swift`. Run the rows with the marker guard in place, top to bottom:

| Site | Mutation | Must fail |
| --- | --- | --- |
| marker guard | delete the `guard` line | `aSecondTileMigrationChangesNothing` |
| marker last | swap the last two lines of `run()` | `theTileMigrationWritesItsMarkerLast` |
| pause | `isPaused: chosen.map { $0.isEnabled } ?? false` | `everyConnectorBecomesATileOnTheClockInRegistrationOrder` |
| refresh from the old key | `Int(connector.defaultInterval)` | `aPositionPastTheEndOfTheScaleBecomesTheLongestRefresh`, `everyConnectorBecomesATileOnTheClockInRegistrationOrder` |
| index → seconds | `Int(chosen.map { TimeInterval($0.intervalPosition) } ?? connector.defaultInterval)` | `everyConnectorBecomesATileOnTheClockInRegistrationOrder` |
| unconfigured default | `?? 1800` in place of `?? connector.defaultInterval` | `everyConnectorBecomesATileOnTheClockInRegistrationOrder` |
| last delivery | `lastDeliveredAt: nil` | `everyConnectorBecomesATileOnTheClockInRegistrationOrder` |
| starts from the old keys | after the guard insert `guard TileStore(defaults: defaults).all().isEmpty else { defaults.set(true, forKey: Self.markerKey); return }` | `aTileMigrationCutShortStartsAgainFromTheOldKeys` |
| old keys untouched | insert `defaults.removeObject(forKey: "connector.anecdotes")` before the marker | `theTileMigrationLeavesTheOldKeysAsTheyWere` |

- [ ] **Step 6: Leave staged, no commit** — committed with Task 7.

---

### Task 7: The schedule and the host read each connector from its tile

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` — `live()` only
- Modify: `Tests/PixelClockTilesAppTests/RecordWiringTests.swift`

**Interfaces:**
- Consumes (existing, verified): in `live()`, `let store = UserDefaultsSettingsStore(defaults: defaults)` (≈557), passed to `ConnectorHost(device:registry:store:audio:iconInstaller:borrowedOverlays:)` and to `AppModel(… store: store …)`; `ConnectorRegistry.all: [any Connector]`; `Connector.id`, `Connector.defaultInterval: TimeInterval`; `AppModel.settings(for connector: any Connector) -> ConnectorSettings`; `AppModel.runNow(_ id: String)`; `AppModel.lastResults: [String: String]` (`.skipped` is recorded as `"off"`); `AppModel.teardown() async`; `ConnectorRegistry.connector(id:)`; `waitUntil(_:limit:)` in `Doubles.swift`. Tasks 3–6.
- Produces: no new API. `live()` gives `ConnectorHost` and `AppModel` one `TileSettingsStore` over the first clock.

- [ ] **Step 1: Write the failing tests** — append to `Tests/PixelClockTilesAppTests/RecordWiringTests.swift`:

```swift
/// The tile `TileMigration` gave a connector on the launch's clock, changed
/// the way a later phase's editor would change it.
private func editTile(
    _ connectorId: String, in defaults: UserDefaults, _ change: (inout TileRecord) -> Void
) throws {
    let clock = try #require(ClockStore(defaults: defaults).all().first)
    let key = TileKey(clockId: clock.id, connectorId: connectorId)
    let tile = try #require(TileStore(defaults: defaults).all().first(where: { $0.key == key }))
    TileStore(defaults: defaults).update(tile, change)
}

// The phase's second claim, for the schedule's half: the switch and the
// interval the panel shows are the tile's.
@Test @MainActor func theLaunchReadsEachConnectorsCadenceFromItsTile() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    try editTile("anecdotes", in: defaults) {
        $0.policy.isPaused = true
        $0.policy.refreshSeconds = 3600
    }

    let relaunched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    let anecdotes = try #require(relaunched.registry.connector(id: "anecdotes"))
    #expect(
        relaunched.settings(for: anecdotes)
            == ConnectorSettings(isEnabled: false, intervalPosition: 11)
    )
}

// And the host's half. `live()` builds the host and the model separately, and
// a host still reading `connector.<id>` would run a paused connector on
// "Run now" — its enablement guard answers `.skipped` only from the store it
// was given.
@Test @MainActor func aPausedTileIsOffForTheHostAsWell() async throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    try editTile("weather", in: defaults) { $0.policy.isPaused = true }
    let relaunched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    relaunched.runNow("weather")

    #expect(await waitUntil { relaunched.lastResults["weather"] == "off" })
    await relaunched.teardown()
}

// The upgrade, end to end. Green before this task as well — the old store
// read the old key directly — and kept because from here on it is the only
// thing proving the step runs at launch, on the clock the launch drives, after
// every connector is registered.
@Test @MainActor func anUpgradedInstallationKeepsEachConnectorsChoice() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    UserDefaultsSettingsStore(defaults: defaults).save(
        ConnectorSettings(isEnabled: false, intervalPosition: 11), for: "anecdotes"
    )

    let launched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    let anecdotes = try #require(launched.registry.connector(id: "anecdotes"))
    #expect(
        launched.settings(for: anecdotes)
            == ConnectorSettings(isEnabled: false, intervalPosition: 11)
    )
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter RecordWiringTests`
Expected: FAIL. `theLaunchReadsEachConnectorsCadenceFromItsTile`: `#require` of the tile fails, because nothing creates tiles yet. `aPausedTileIsOffForTheHostAsWell`: the same. `anUpgradedInstallationKeepsEachConnectorsChoice` passes (characterisation, see its comment).

- [ ] **Step 3: Implement — `live()`**

Delete:

```swift
        let store = UserDefaultsSettingsStore(defaults: defaults)
```

After the last `registry.register(ClaudeUsageConnector(…))` call and before `return AppModel(`, insert:

```swift
        // After every connector is registered: one the step does not hear
        // about gets no tile, and runs on its own default until its first
        // saved choice gives it one.
        try? TileMigration(
            defaults: defaults,
            clockId: clock.id,
            connectors: registry.all.map { (id: $0.id, defaultInterval: $0.defaultInterval) }
        ).run()
        let store = TileSettingsStore(defaults: defaults, clockId: clock.id)
```

`ConnectorHost(… store: store …)` and `AppModel(… store: store …)` below it are unchanged and now receive the tiles' store.

- [ ] **Step 4: Run to verify everything passes**

Run: `swift test --filter 'TileStoreTests|TileSettingsStoreTests|TileMigrationTests|RecordWiringTests'`
Expected: PASS.
Then: `swift test`
Expected: PASS for the whole suite. The `UserDefaultsSettingsStore` tests in `ConnectorHostTests.swift` still pass: the type stays, as the migration's reader of the old keys.

- [ ] **Step 5: Mutation check**

`git add` the two files, then one site at a time, reverting with `git checkout -- Sources/PixelClockTilesApp/AppModel.swift`:

| Site | Mutation | Must fail |
| --- | --- | --- |
| the model's store | pass `store: UserDefaultsSettingsStore(defaults: defaults)` to `AppModel(` only | `theLaunchReadsEachConnectorsCadenceFromItsTile` |
| the host's store | pass `store: UserDefaultsSettingsStore(defaults: defaults)` to `ConnectorHost(` only | `aPausedTileIsOffForTheHostAsWell` |
| the step runs | delete the `TileMigration` call | `anUpgradedInstallationKeepsEachConnectorsChoice` |
| on the driven clock | `clockId: UUID()` in the `TileMigration` call | `anUpgradedInstallationKeepsEachConnectorsChoice` |
| after registration | move the `TileMigration` call to directly under `let registry = ConnectorRegistry()` | `anUpgradedInstallationKeepsEachConnectorsChoice` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Tiles \
  Sources/PixelClockTilesApp/TileMigration.swift Sources/PixelClockTilesApp/AppModel.swift \
  Tests/PixelClockKitTests/TileStoreTests.swift Tests/PixelClockKitTests/TileSettingsStoreTests.swift \
  Tests/PixelClockTilesAppTests/TileMigrationTests.swift Tests/PixelClockTilesAppTests/RecordWiringTests.swift
git commit -m "feat: read each connector's cadence and pause from its tile

Tiles, their store, the migration step and the SettingsStore that serves
them to ConnectorHost and AppModel land together. connector.<id> is read
once and never written again; ConnectorHost is not touched."
```

---

### Task 8: Record the split migration in the spec and the handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md` — § Clock table (`hardwareIdentity` row), § Persistence and migration (the paragraph under the keys and the table)
- Modify: `docs/HANDOFF.md` — "What later tasks owe", "What only a person at the hardware can settle"

- [ ] **Step 1: The spec's clock table**

Replace the `hardwareIdentity` row with:

```markdown
| `hardwareIdentity` | AWTRIX `uid` from `/api/stats`; TC002 `devSn` from `/getBase`. Nil until the clock has answered once |
```

- [ ] **Step 2: The spec's migration section**

Replace from `Migration of an existing installation runs once and is idempotent.` through the last row of the `| Old | New |` table with:

```markdown
Migration of an existing installation runs as steps. Each step runs once and is
idempotent: its marker is written last, so a step that fails part-way runs
again from the old keys on the next launch rather than leaving half a model.
The old keys are never written or removed. A row moves in the phase that stops
the app writing its source key. Before then the old UI still writes it, and a
copy taken earlier would be stale by the time anything read it — for the
borrowed overlay, a loan already given back.

| Old | New | Step · phase |
| --- | --- | --- |
| `deviceHost`; absent, `192.168.1.72`, the address the launch used | one AWTRIX clock named "Clock" | `migration.clocks` · 1 |
| `deviceUID` | that clock's `hardwareIdentity` | `migration.clocks` · 1 |
| `connector.<id>` for every registered connector; absent or unreadable, the connector's defaults | a tile on that clock; `isEnabled` → `!isPaused`; interval index → duration → seconds; `lastDeliveredAt` kept | `migration.tiles` · 1 |
| `quietStartHour` / `quietEndHour` | `window: .quiet(…)` on the audible tiles | 4 |
| `weatherLocation` | the weather tile's `config` | 4 |
| the always-on VPN lamps | two VPN tiles, both `whenUnknown: hold` (today a Focus that cannot be named leaves both lamps dark): Pritunl on the top lamp, working in Work only, `#90EE90`, down → blink `#FF0000`; Amnezia on the bottom lamp, working in Work and Personal, `#A855F7`, down → off | 4 |
| the borrowed overlay | `borrowedOverlay.<clockId>` of that clock | the phase that keys custody by clock |
| `batteryHistory` | `batteryHistory.<uid>` | the phase that keys health by clock |
```

- [ ] **Step 3: HANDOFF — what later tasks owe**

Append at the end of "What later tasks owe":

```markdown
**PixelClockTiles, left by phase 1** (plan
`docs/superpowers/plans/2026-09-18-pixelclocktiles-phase1-domain-persistence.md`):

- The migration is a series of steps, each with its own marker, written last.
  Phase 1 ran `migration.clocks` and `migration.tiles`. A later step reads the
  old keys when it lands — they are never removed — and moves a row in the
  same commit that stops the app writing its source key.
- Phase 4 owes the step for the quiet hours, `weatherLocation` and the VPN
  lamps. It extends `TilePolicyRecord` with optional keys for the Focus and the
  hours; a tile without them has not been through that step.
- Whichever phase keys custody and health by clock owes the steps for
  `borrowedOverlay` and `batteryHistory`, in the commit that re-keys them.
- `TileSettingsStore.save` keeps the stored seconds while the slider position
  they snap to has not moved. It retires with the adapter when the scheduler
  reads `TileRecord` directly; until then nothing may write seconds that the
  old scale cannot show except through a moved slider.
- `ClockStore.firstClock(orCreatingAt:)` creates a clock when none is stored.
  Phase 5 removes that branch once "No clocks yet" is a state the user can
  reach, and decides what `ClockMigration` does on a fresh install.
```

- [ ] **Step 4: HANDOFF — at the hardware**

Append after the last "Added by wave 4" item:

```markdown
### Added by PixelClockTiles phase 1

30. **An upgrade keeps what the user had.** Install the phase 1 build over the
    previous one and open the panel: the clock at the same address, the
    anecdote interval and switch as they were, and the next anecdote due at the
    remainder of the interval rather than a fresh one. Then let the clock drop
    off the network and come back at a new address: the app follows it, which
    is the migrated `deviceUID` at work.
```

- [ ] **Step 5: Lint and commit**

Run: `markdownlint docs/HANDOFF.md docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md` if it is installed; otherwise say so and go on.

```bash
git add docs/HANDOFF.md docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md
git commit -m "docs: migrate each row in the phase that stops writing its key"
```

---

## What later phases inherit

- **Stored shapes.** `clocks`: `[{"id","name","model","address","hardwareIdentity"?}]`, `model` ∈ `awtrix3`, `ulanziTC002`. `tiles`: `[{"key":{"clockId","connectorId","instance"},"policy":{"isPaused","refreshSeconds"},"lastDeliveredAt"?}]`. Both are pinned by a test that decodes a literal. A new field is added as an optional, so a record written before it existed still decodes.
- **Markers.** `migration.clocks` and `migration.tiles` exist. A new step picks a new name, runs after these two in `live()`, and writes its marker last.
- **Readers to retire.** `TileSettingsStore` exists only because `ConnectorHost` and `AppModel` speak `ConnectorSettings`. When Phase 4 schedules by `TileKey`, the scheduler reads `TileStore` directly and the adapter goes, its snap guard with it. `UserDefaultsSettingsStore` stays as long as a migration step reads `connector.<id>`.
- **Phase 3.** "The app still drives one clock — the first in `clocks`". That clock is the one `ClockStore.firstClock(orCreatingAt:)` returns in `live()`, and its `model` is what Phase 3 switches on.

## Self-review

- **Spec coverage.** § Clock: `ClockRecord` carries every field in the table (Task 1). § Tile: `TileKey(clockId, connectorId, instance)` with an empty instance for single connectors, `lastDeliveredAt` carried unchanged, `policy` holding the Phase 1 fields (Task 4). `config` is not in Phase 1: nothing reads it before Phase 4 (D3). § Persistence: `clocks` and `tiles` keys, JSON (Tasks 1, 4); markers last, second run a no-op, old keys untouched, snapshot-in/records-out tests (Tasks 2, 6). `selectedClockId`, `ownedApps.<clockId>`, `borrowedOverlay.<clockId>` and `batteryHistory.<hardwareIdentity>` belong to the phases that read them (D3, contact points). Phase 1 row: the clock from `clocks` (Task 3), cadence and pause from the tile (Task 7), a reader in the commit that adds each record (D11).
- **Placeholders.** None: every code step is complete, and every test edit shows its replacement lines.
- **Type consistency.** `ClockStore.update(_:_:)`, `TileStore.update(_:_:)`, `firstClock(orCreatingAt:)`, `TileSettingsStore(defaults:clockId:)`, `ClockMigration(defaults:fallbackHost:)`, `TileMigration(defaults:clockId:connectors:)` and `DeviceHostField.save(_:to:for:)` are spelled the same in every task that uses them.
- **Verified outside the tree.** Tasks 1, 2, 4, 5 and 6 were compiled under Swift 6.3.3 with tools 6.0 in a scratch package, all 37 tests passed, and the mutations sampled from their tables (no lock, snap guard off, marker first, marker guard gone, identity dropped, refresh from the default) each turned a test red. The same run confirmed that `swift test --filter <FileName>` selects the free `@Test` functions of that file. Tasks 3 and 7 edit `AppModel.swift`, which phase 0 is renaming around, and they are verified by their own steps.
