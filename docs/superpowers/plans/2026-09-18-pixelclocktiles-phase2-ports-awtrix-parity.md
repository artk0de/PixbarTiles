# PixelClockTiles Phase 2 — Ports and AWTRIX Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the AWTRIX delivery path the shape the multi-clock design needs without changing what it does. Five changes: a `DeliveryChain` lifted out of `ConnectorHost`, the host renamed to the AWTRIX clock's session, a typed `Delivery<Scene>`, connectors split into `read()` and an `awtrixFace`, and indicator custody moved from the app into the AWTRIX adapter. Every existing test is moved, never rewritten.

**Architecture:** `DeliveryChain` is the model-free part of `ConnectorHost`: the queue, the failure counts, `nextDelay`, and the classification of thrown errors. `AwtrixClockSession` is the rest of `ConnectorHost` (device, payloads, held banner, `DeviceCustody`), and it now also owns `IndicatorCustody`. A connector reads a value and its `AwtrixFace` draws that value as a `Delivery<AwtrixScene>`; `Connector.produce()` joins the two halves and is what the session runs. The app keeps talking to the session through its own `ConnectorRunning` protocol, so the scheduling code in `AppModel` is not touched.

**Tech Stack:** Swift 6.3.3, SwiftPM tools 6.0, macOS 14 floor, `swift-testing`, Swift 6 strict concurrency. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md` — § Architecture, § Connector, § ClockSession, § AWTRIX adapter (TC001), § Connectors and faces, § Phases (row 2). Read `docs/HANDOFF.md` § "How this branch finds defects" before the first task.

## Global Constraints

- Swift tools version `6.0`, platform floor `.macOS(.v14)`. Swift 6 strict concurrency is on; every type that crosses an actor boundary is `Sendable`.
- **No third-party dependencies**, ever. Nothing enters `Package.swift`'s dependency list.
- All source comments, identifiers, commit messages and documentation are English.
- Names after phase 0: module `PixelClockKit` in `Sources/PixelClockKit/`, executable target `PixelClockTilesApp` in `Sources/PixelClockTilesApp/`, tests in `Tests/PixelClockKitTests/` and `Tests/PixelClockTilesAppTests/`. Kit tests start with `@testable import PixelClockKit`; app tests with `import PixelClockKit` and `@testable import PixelClockTilesApp`. AWTRIX-specific types keep their names (`AwtrixDevice`, `AwtrixError`, …).
- **No behaviour change.** Phase 2 is a parity phase (spec § Phases, row 2). A task that changes what reaches the clock, when, or in what order is wrong, however much cleaner it looks.
- **Tests are moved, never rewritten.** The rule, made operational:
  - allowed: moving a test between files; renaming the type or method an arrange/act line calls (`ConnectorOutput` → `AwtrixDelivery`, `ConnectorHost` → `AwtrixClockSession`, a double's `produce()` → `read()`); changing a constructor call in an arrange line when the constructed type moved (`VPNLampDisplay(clock:)` → `VPNLampDisplay(indicators: IndicatorCustody(lamps:))`); adapting a test double to a changed protocol;
  - forbidden: changing any `#expect`, `#require` or `Issue.record` line beyond those renames; deleting a test; changing what a test arranges or does.
  - Task 6 checks this mechanically over the whole phase.
- New tests go only into **new files**, so the audit in Task 6 can treat every modified test file as rename-only.
- `Sources/PixelClockTilesApp/MenuPanel.swift` is not touched by this phase (21 commits, 48% fixes). `AppModel.swift` (31 commits, 42% fixes) is touched only in its two protocol declarations, one conformance line, three doc comments and `live()`. No method body outside `live()` changes.
- A Ulanzi TC002 at `192.168.1.72` is live on the LAN. No test and no step makes a network call to it; every request in this plan goes through an injected `Transport` double.
- Mutation discipline (HANDOFF): mutate **one site at a time**; after adding a guard, re-run the mutations of the guards it sits in front of. Mutations are run after the task's commit, on a clean tree, and each is reverted with `git restore <file>` before the next.

---

## Decisions this plan takes

Recorded so the executor does not re-open them. Where a decision departs from the spec's text, the spec correction is stated.

| # | Decision | Why |
| --- | --- | --- |
| D1 | The app-facing protocol stays `ConnectorRunning` (in `AppModel.swift`); the kit type is `AwtrixClockSession`. | Phase 3 needs a TC002 session beside it, so the kit type is named for its model. Renaming `ConnectorRunning` to `ClockSession` touches every host double in `Doubles.swift` and belongs with Phase 4's session-per-clock rewrite of `AppModel`. |
| D2 | `DeliveryChain` is keyed by `String` connector id. | Phase 4 introduces `TileKey`, and it is the first reader of a non-string key. The chain becomes generic over its key then. |
| D3 | `Delivery<Scene>` keeps the name `localAudio` for the audio, not the spec's `audio`. | Every moved assertion about sound reads `output.localAudio` (`WeatherConnectorTests`, `AnecdoteConnectorTests`, `ConnectorRegistryTests`, `AppShellTests`). **Spec correction:** `Delivery<Scene>{scene, localAudio, holdUntilAudioEnds}`. |
| D4 | `Delivery` is `@dynamicMemberLookup` over its scene, read-only. | Moved assertions read `output.text`, `output.surface`, `output.overlay`, … on the value a connector produces. The lookup keeps each of them byte-identical, and the session's `send` keeps its lines too, so the session's payload code does not move at all. |
| D5 | `AwtrixScene` is a **struct** carrying a `surface: DeliverySurface`, not the spec's enum `.notification(…) / .app(name, payload, overlay?) / .indicator(slot, signal)`. | Under the enum, moved tests such as `aLifetimeIsNeverSentOnANotification` cannot be constructed: they pin that the adapter drops a lifetime set on a notification. **Spec correction:** the enum shape is a later refinement, and `.indicator` joins the scene in Phase 4 with the VPN tile's face. Indicator writes stay **off** the delivery chain — today a lamp never waits behind a playing anecdote, and queueing it would delay a lamp by an anecdote's length. |
| D6 | `awtrixFace` is **non-optional**. | Every connector in the spec has an AWTRIX face and nothing in Phase 2 reads the optionality. **Spec correction:** `awtrixFace` becomes optional only when a TC002-only connector exists. Phase 3b adds `ulanziFace` as optional with a `nil` default in a protocol extension, so no AWTRIX-only connector changes. |
| D7 | No `associatedtype Config` in Phase 2; `read()` takes no argument. | Nothing in Phase 2 reads a config. A `NoConfig` threaded through three connectors would be scaffolding. **Spec correction:** `Config` lands in Phase 4 together with its first reader, the weather tile's location. |
| D8 | `ClockModel` is **not** defined here. | Its first reader is Phase 1's `ClockRecord.model`. Defining it in Phase 2 as well would collide with that lane. |
| D9 | Health (`DeviceMonitor`, `BatteryTrajectory`, relocation) stays in `AppModel`. | The Phase 2 row does not list it, and moving it rewrites `poll()`, the glyph and relocation — the riskiest code in the file. **Spec note:** the spec's § ClockSession lists health on the session; it moves there in Phase 4, when there is a session per clock. |
| D10 | `Connector.produce()` survives as a protocol-extension method: `awtrixFace.draw(try await read())`. It is the AWTRIX program the session runs. | The session keeps calling `connector.produce()`, and about fifty moved tests call it by that name. Phase 3b names the TC002 counterpart. |
| D11 | The drawing tests stay in `WeatherConnectorTests.swift`, `ClaudeUsageTests.swift` and `AnecdoteConnectorTests.swift`. | They already call the face function by name (`ClaudeUsageConnector.output(for:)`, `AnecdoteConnector.output(for:)`) or go through `produce()`, which is now read-then-face. Moving the weather ones would mean making `WeatherConnectorTests`' private `Clock` fixture internal, and that name would then shadow `_Concurrency.Clock` across the whole test module. **Spec note:** "move to face tests" becomes a file move in Phase 3b, when TC002 face tests land beside them. |
| D12 | `IndicatorCustody` (kit) holds the lamp state: `show(_:on:)` writes only a change and forgets a failed write. `VPNLampDisplay` (app) shrinks to the VPN-specific mapping of two corners onto that custody, and its `clear()` stays `show(.dark)`. | Today a quit writes `.off` to both corners even if they were never lit. A generic "put out what was lit" would skip that write when the app quits before its first refresh — a behaviour change. The generic quit rule comes in Phase 4, when lamps belong to tiles. |
| D13 | Claude usage: the session and the faces depend only on `ClaudeUsageReporting.read() async throws -> ClaudeUsageReading?`, `ClaudeUsageConnector.init(reporter:showsNow:)`, `ClaudeUsageConnector.output(for:)` and `ClaudeUsageReading`'s `utilization` / `resetsAt`. | Lane C is replacing the reporter, the credential types and the `/api/oauth/usage` parsing. This plan does not move, restructure or re-test any of them. |

## Impact signals

tea-rags returned chunks only for `AppModel.swift` (its codegraph index is drifting). The other rows come from `git log --follow` at `39d7072`. Every file has a single author (`artk0de`, 100% blame), so ownership says nothing about review routing. The signal that matters is the fix rate.

| File (new path) | Commits | Fix commits | Tasks touching it |
| --- | --- | --- | --- |
| `Sources/PixelClockTilesApp/AppModel.swift` | 31 | 13 (42%) | 2, 3, 5 — declarations and `live()` only |
| `Sources/PixelClockTilesApp/MenuPanel.swift` | 21 | 10 (48%) | none |
| `Tests/PixelClockTilesAppTests/Doubles.swift` | 24 | 8 | 2, 3, 4 — renames only |
| `Tests/PixelClockKitTests/ConnectorHostTests.swift` | 14 | 3 | 2 (moved), 3, 4 — renames only |
| `Sources/PixelClockKit/Scheduling/ConnectorHost.swift` | 11 | 3 | 1, 2 (moved), 3, 4, 5 |
| `Sources/PixelClockKit/Connectors/Connector.swift` | 11 | 2 | 2, 3, 4 |
| `Sources/PixelClockKit/Connectors/WeatherConnector.swift` | 11 | 2 | 3, 4 |
| `Sources/PixelClockKit/Connectors/AnecdoteConnector.swift` | 8 | 3 | 3, 4 |
| `Sources/PixelClockKit/Device/DeviceCustody.swift` | 2 | 1 | none |
| `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` | 2 | 0 | 3, 4 |
| `Sources/PixelClockTilesApp/VPNLampDisplay.swift` | 1 | 0 | 5 |

The ordering follows from these numbers. The two high-fix files are either left alone (`MenuPanel`) or touched only at their seams (`AppModel`). Every change to the delivery path lands on the session, which carries 53 tests of its own and is covered again by `RetryPolicyTests`, `WeatherConnectorTests` and `AnecdoteConnectorTests`.

## File structure

| Path | Responsibility | Task |
| --- | --- | --- |
| `Sources/PixelClockKit/Scheduling/DeliveryChain.swift` (new) | `RunResult`; the chain: queue, failure counts, `nextDelay`, `classify` | 1 |
| `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift` (moved from `Scheduling/ConnectorHost.swift`) | The AWTRIX clock's session: guards, payloads, held banner, overlay/app custody, lamp custody | 1, 2, 3, 4, 5 |
| `Sources/PixelClockKit/Connectors/Delivery.swift` (new) | `Delivery<Scene>` — a scene plus the Mac-side audio | 3 |
| `Sources/PixelClockKit/Awtrix/AwtrixScene.swift` (new) | `IconReference`, `DeliverySurface`, `ProgressBar` (moved), `AwtrixScene`, `AwtrixDelivery` | 3 |
| `Sources/PixelClockKit/Awtrix/AwtrixFace.swift` (new) | `AwtrixFace<Reading>` | 4 |
| `Sources/PixelClockKit/Awtrix/IndicatorCustody.swift` (new) | `IndicatorLighting` (moved from the app), `IndicatorCustody` | 5 |
| `Sources/PixelClockKit/Connectors/Connector.swift` | `SpokenClip`, `Connector` (`read`, `awtrixFace`), `produce()`, `ConnectorMaintaining`, `MaintenanceResult` | 2, 3, 4 |
| `Sources/PixelClockKit/Connectors/{Weather,ClaudeUsage,Anecdote}Connector.swift` | `read()` + `awtrixFace` | 3, 4 |
| `Sources/PixelClockKit/Audio/SequentialAudioPlayer.swift` | gains `AudioPlaying` (moved) | 2 |
| `Sources/PixelClockKit/Device/CatalogueIconInstaller.swift` | gains `IconInstalling` (moved) | 2 |
| `Sources/PixelClockTilesApp/VPNLampDisplay.swift` | VPN corners onto `IndicatorCustody` | 5 |
| `Sources/PixelClockTilesApp/AppModel.swift` | declarations + `live()` | 2, 3, 5 |
| `Tests/PixelClockKitTests/DeliveryChainTests.swift` (new) | the chain on its own | 1 |
| `Tests/PixelClockKitTests/AwtrixClockSessionTests.swift` (moved from `ConnectorHostTests.swift`) | unchanged tests | 2 |
| `Tests/PixelClockKitTests/AwtrixDeliveryTests.swift` (new) | the scene/audio split | 3 |
| `Tests/PixelClockKitTests/ConnectorFaceTests.swift` (new) | read and face, per connector | 4 |
| `Tests/PixelClockKitTests/PassThroughFace.swift` (new) | test-only default face for doubles | 4 |
| `Tests/PixelClockTilesAppTests/PassThroughFace.swift` (new) | the same, for the app's doubles | 4 |
| `Tests/PixelClockKitTests/IndicatorCustodyTests.swift` (new) | lamp custody on its own | 5 |
| `Tests/PixelClockTilesAppTests/IndicatorCustodyWiringTests.swift` (new) | `live()` hands the session's custody to the lamps | 5 |

## Contact points with parallel lanes

Phase 1 (clock and tile records, migration), Phase 3a (TC002 leaf adapter), Phase 4 Part A (pure `TilePolicy` types) and lane C (the Claude usage source) run in parallel with this plan. Line numbers are as of `39d7072`; locate by symbol when they have moved.

| File / symbol | What this plan does | Other lane | Merge rule |
| --- | --- | --- | --- |
| `AppModel.swift` — `protocol ConnectorRunning` (L16–36) and `extension ConnectorHost: ConnectorRunning {}` (L38) | Task 2 renames the conformance to `AwtrixClockSession`. Task 3 changes `deliver(_ output: ConnectorOutput)` to `deliver(_ output: AwtrixDelivery)`. | none expected | — |
| `AppModel.swift` — `protocol AnecdoteReplaying` (L51–55) | Task 3: `output(for:) -> AwtrixDelivery` | none expected | — |
| `AppModel.swift` — doc comments at L14, L430, L961, L1829 | Task 2 renames `ConnectorHost` in comments | none expected | — |
| `AppModel.live()` (L535–631) | Task 2: `host: AwtrixClockSession(`. Task 5 hoists `let session = AwtrixClockSession(…)` above `return AppModel(`, then passes `host: session` and `vpnLamps: VPNLampDisplay(indicators: session.indicators)` | **Phase 1** rewrites how `deviceHost` and `store` are obtained. **Lane C** replaces the `ClaudeUsageReporter(transport: transport)` line (L586) | Phase 2 consumes the local values `device`, `registry`, `store`, `installer`, `defaults` whatever produces them, and never edits the reporter line. Keep Phase 1's and lane C's lines; re-apply Phase 2's three edits on top. |
| `AppModel.init`, `poll`, `followTheClock`, the schedule | untouched | Phase 1 (clock record writes) | no overlap |
| `Sources/PixelClockKit/Scheduling/ConnectorSettings.swift` — `SettingsStore` (`storedSettings(for:)`, `save(_:for:)`, extension `settings(for:)`) | untouched. The session reads `store.settings(for: connectorId).isEnabled` exactly as `ConnectorHost` does; `DeliveryChain` takes no store. | Phase 1 swaps the implementation behind this seam | seam shape unchanged by Phase 2 |
| `Tests/PixelClockKitTests/ConnectorHostTests.swift` → `AwtrixClockSessionTests.swift` | Task 2 `git mv`; Tasks 2–4 rename types | Phase 1 may edit the file's "Settings" section (L1157–1300) | git's rename detection carries Phase 1's hunks. If Phase 1 lands first, rebase Task 2 onto it. |
| `Tests/PixelClockTilesAppTests/Doubles.swift` | Task 2: `waitForFailures(of:on:toReach:limit:)` and `modelOverRealHost` host type. Task 3: `deliver`/`output(for:)` types in `SpyHost`, `QueueingHost`, `CancellingHost`, `RestockReportingHost`, `StubAnecdotes`. Task 4: `StubConnector` and `BrokenConnector` `produce()` → `read()` | Phase 1 may change `testModel` / `modelOverRealHost` store and defaults | Phase 2 touches only the `ConnectorHost(`/`-> (model: AppModel, host: ConnectorHost)` tokens inside `modelOverRealHost`. |
| `Tests/PixelClockTilesAppTests/AppShellTests.swift` | Task 3 renames `ConnectorOutput` (L184, L246–252). Task 2 renames comments (L213, L359). | Phase 1: the `deviceHost` tests (L395–412) | disjoint lines |
| `Tests/PixelClockTilesAppTests/AppModelTests.swift` L1334 | Task 2 type rename | Phase 1 may touch model construction | one token |
| `ClaudeUsageConnector.swift` | Task 3 type rename. Task 4 splits `produce()` into `read()` + `awtrixFace`; `output(for:)` body unchanged | **Lane C** replaces what sits behind `ClaudeUsageReporting` | Phase 2 relies on: `ClaudeUsageReporting.read() async throws -> ClaudeUsageReading?`, `init(reporter:showsNow:)`, `Failure.outOfFocus` / `.noReading`, `ClaudeUsageReading.utilization` / `.resetsAt`, and `ClaudeUsageReading(utilization:resetsAt:)`, which `ConnectorFaceTests` constructs. Lane C keeps that initializer or gives any new parameter a default. |
| `ClaudeUsageReading.swift`, `ClaudeCredentials.swift`, `ClaudeUsageReporter.swift`, `ClaudeUsageTests.swift`, `ClaudeUsageReporterTests.swift` | not edited. The new Claude tests go into `ConnectorFaceTests.swift`. | **Lane C** deletes and rewrites these | no overlap |
| `Connector.swift`, `Delivery.swift` | Task 3 creates `Delivery<Scene: Sendable & Equatable>`; Task 4 splits the protocol | **Phase 3a** builds `UlanziScene`. **Phase 3b** adds `ulanziFace` | `UlanziScene` must be `Sendable & Equatable` to become `Delivery<UlanziScene>`. Phase 3b adds `var ulanziFace: UlanziFace<Reading>? { get }` with `nil` default in a protocol extension. Phase 3a must not define `Delivery`. |
| `ClockModel` | not defined here | **Phase 1** (`ClockRecord.model`) | — |
| `Sources/PixelClockKit/Awtrix/` (new directory) | Tasks 2–5 add files | Phase 3a keeps TC002 files in its own directory | no overlap |
| `docs/HANDOFF.md` | Task 6 appends one section | every lane | append-only; merge by concatenation |
| Phase 4 Part A (`TilePolicy`, `FocusState`, `HourWindow`) | none | Phase 4 Part A | no overlap |

---

### Task 0: Baseline on the renamed tree

No code and no commit. The task records what parity is measured against.

**Files:** none.

**Interfaces:**
- Consumes: the tree after phase 0 (and after Phase 1's commits, if they have landed).
- Produces: `BASE` (a commit hash) and `N0` (a test count), which Task 6 reads. If another lane's commits are merged into this branch mid-phase, re-take `N0` on the merge and add that lane's new tests to it; every "`N0 + k`" below counts only this plan's own tests.

- [ ] **Step 1: Confirm the phase 0 names are on disk**

Run: `ls Sources/PixelClockKit/Scheduling/ConnectorHost.swift Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockKitTests/ConnectorHostTests.swift Tests/PixelClockTilesAppTests/Doubles.swift`
Expected: all four paths print. If any is missing, phase 0 has not landed; stop.

- [ ] **Step 2: Build with no warnings**

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

- [ ] **Step 3: Run the suite and record the count**

Run: `swift test 2>&1 | tail -3`
Expected: PASS. Under heavy machine load four wall-clock tests are known to flake (HANDOFF § State). Re-run before treating a red among them as a defect.

Run: `swift test --list-tests 2>/dev/null | wc -l`
Expected: a number. Write it down as `N0` (999 at `39d7072`, before phase 0 and Phase 1 added tests).

- [ ] **Step 4: Record the base commit**

Run: `git rev-parse HEAD`
Write the hash down as `BASE`.

---

### Task 1: Lift the delivery chain out of `ConnectorHost`

**Files:**
- Create: `Sources/PixelClockKit/Scheduling/DeliveryChain.swift`
- Modify: `Sources/PixelClockKit/Scheduling/ConnectorHost.swift` (L29–39 `RunResult` deleted; L59 `retryPolicy`, L67–76 `tail`/`failureCounts` replaced by `chain`; L98 init; L120–174 counts, delay and record; L207–218 `runOnce` tail; L239–241 `deliver`; L243–275 `queued` deleted; L315–321 and L407–409 `classify` calls; L412–429 `classify` deleted)
- Test: `Tests/PixelClockKitTests/DeliveryChainTests.swift` (new)
- Unchanged and must stay green: `ConnectorHostTests.swift` (53), `RetryPolicyTests.swift` (11), `WeatherConnectorTests.swift` (30), `AnecdoteConnectorTests.swift` (44), all app tests.

**Interfaces:**
- Consumes: `struct RetryPolicy` — `init(base: TimeInterval = 30, cap: TimeInterval = 1800)`, `func delay(afterConsecutiveFailures failures: Int) -> TimeInterval`.
- Produces:
  - `public enum RunResult: Sendable, Equatable { case delivered, skipped, cancelled, failed(String) }` (moved, unchanged)
  - `public actor DeliveryChain`
    - `public init(retryPolicy: RetryPolicy = RetryPolicy())`
    - `public func run(for connectorId: String, _ work: @escaping @Sendable () async -> RunResult) async -> RunResult` — queued, then recorded
    - `public func deliver(_ work: @escaping @Sendable () async -> RunResult) async -> RunResult` — queued, recorded against nothing
    - `public func consecutiveFailures(connectorId: String) -> Int`
    - `public func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval`
    - `public static func classify(_ error: any Error) -> RunResult`
  - `ConnectorHost.consecutiveFailures(connectorId:)` and `ConnectorHost.nextDelay(connectorId:interval:)` become `async` forwards. Every caller already awaits them across the actor boundary; `ConnectorRunning.nextDelay` is already `async`.
- Production caller of every new member: `ConnectorHost` (`runOnce` → `run(for:_:)`, `deliver` → `deliver(_:)`, the two forwards, `produceAndSend`/`send` → `classify`).

**Proven template:** `ConnectorHost.queued(_:)` itself, moved verbatim. `AnecdotePreparer.refill(target:)` is the repo's second use of the same tail-chain idiom and shows that the idiom survives on an actor of its own.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/DeliveryChainTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The chain on its own, with no clock behind it. Everything here was already
// true of `ConnectorHost`, and is pinned there too, through a device. These say
// it of the chain alone, because the TC002's session will hold one without the
// AWTRIX session's tests around it.

/// Parks work handed to the chain until the test lets it go.
///
/// A continuation rather than a sleep, and deliberately not cancellation-aware:
/// a sleep would throw on cancellation and answer the question these tests ask
/// before the chain gets to.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var entered = 0

    var enteredCount: Int { lock.withLock { entered } }

    func open() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            let all = waiting
            waiting = []
            return all
        }
        held.forEach { $0.resume() }
    }

    func enter() async {
        lock.withLock { entered += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// How many pieces of work have started, and the most that were ever inside
/// the chain at once.
private final class Occupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var peak = 0
    private var started = 0

    var highest: Int { lock.withLock { peak } }
    var startedCount: Int { lock.withLock { started } }

    func enter() {
        lock.withLock {
            inside += 1
            started += 1
            peak = max(peak, inside)
        }
    }

    func leave() { lock.withLock { inside -= 1 } }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(waitBudget(nil))
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

// A run and a replay take their turns in one queue. `dismissNotification` is
// global to an AWTRIX clock, so two deliveries inside at once end with one
// taking down the other's banner mid-speech.
@Test func theChainRunsOnePieceOfWorkAtATime() async throws {
    let chain = DeliveryChain()
    let latch = Latch()
    let occupancy = Occupancy()
    let work: @Sendable () async -> RunResult = {
        occupancy.enter()
        await latch.enter()
        occupancy.leave()
        return .delivered
    }

    let first = Task { await chain.run(for: "a", work) }
    try await waitUntil { latch.enteredCount == 1 }
    let second = Task { await chain.deliver(work) }
    // Long enough for an unserialised second piece to have started.
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(occupancy.startedCount == 1)

    latch.open()
    #expect(await first.value == .delivered)
    #expect(await second.value == .delivered)
    #expect(occupancy.highest == 1)
}

// Cancellation cannot break the wait for a predecessor, so the check on the far
// side of that wait is what keeps a cancelled delivery off the clock.
@Test func workCancelledWhileQueuedNeverStarts() async throws {
    let chain = DeliveryChain()
    let latch = Latch()
    let occupancy = Occupancy()

    let first = Task { await chain.run(for: "a") { await latch.enter(); return .delivered } }
    try await waitUntil { latch.enteredCount == 1 }
    let queued = Task { await chain.run(for: "a") { occupancy.enter(); return .delivered } }
    try await Task.sleep(nanoseconds: 20_000_000)
    queued.cancel()
    latch.open()

    #expect(await queued.value == .cancelled)
    #expect(await first.value == .delivered)
    #expect(occupancy.startedCount == 0)
}

// The work runs in an unstructured task, which inherits nothing from its
// caller. Without cancellation forwarded by hand, a caller that gives up gets
// neither the work stopped nor itself back.
@Test func aCallerThatGivesUpCancelsTheWorkItWasWaitingFor() async throws {
    let chain = DeliveryChain()
    let occupancy = Occupancy()
    let run = Task {
        await chain.run(for: "a") {
            occupancy.enter()
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return .cancelled }
            return .delivered
        }
    }
    try await waitUntil { occupancy.startedCount == 1 }

    let cancelledAt = ContinuousClock.now
    run.cancel()

    #expect(await run.value == .cancelled)
    #expect(ContinuousClock.now - cancelledAt < .seconds(1))
}

// The backoff describes the feed. A replay says nothing about it, and neither
// does a delivery somebody called off.
@Test func aRunsOutcomeIsCountedAndADeliverysIsNot() async {
    let chain = DeliveryChain()
    _ = await chain.run(for: "a") { .failed("down") }
    _ = await chain.run(for: "a") { .failed("down") }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 2)

    _ = await chain.deliver { .failed("refused") }
    _ = await chain.deliver { .delivered }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 2)

    _ = await chain.run(for: "a") { .cancelled }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 2)

    _ = await chain.run(for: "a") { .delivered }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 0)
    #expect(await chain.consecutiveFailures(connectorId: "b") == 0)
}

// A failing connector is retried sooner than its cadence and never later.
@Test func theBackoffIsClippedToTheCadence() async {
    let chain = DeliveryChain(retryPolicy: RetryPolicy(base: 30, cap: 1800))
    #expect(await chain.nextDelay(connectorId: "a", interval: 600) == 600)

    _ = await chain.run(for: "a") { .failed("down") }

    #expect(await chain.nextDelay(connectorId: "a", interval: 600) == 30)
    #expect(await chain.nextDelay(connectorId: "a", interval: 10) == 10)
}

// One reading of a thrown error for both halves of a run. Only the two ways a
// cancellation arrives read as one; a timeout is an outage.
@Test func onlyACancellationIsReadAsOne() {
    #expect(DeliveryChain.classify(CancellationError()) == .cancelled)
    #expect(DeliveryChain.classify(URLError(.cancelled)) == .cancelled)
    guard case .failed = DeliveryChain.classify(URLError(.timedOut)) else {
        Issue.record("a timeout is an outage, not a cancellation")
        return
    }
    guard case .failed = DeliveryChain.classify(AwtrixError.invalidHost("nowhere")) else {
        Issue.record("a device fault is a failure")
        return
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DeliveryChainTests`
Expected: FAIL at compile time — `cannot find 'DeliveryChain' in scope`.

- [ ] **Step 3: Create `DeliveryChain.swift`**

`RunResult` moves here from `ConnectorHost.swift` unchanged. `queued(_:)`, `record(_:for:)`, `nextDelay` and `classify` move unchanged, doc comments included. Only the words naming their caller are updated.

```swift
// Sources/PixelClockKit/Scheduling/DeliveryChain.swift
import Foundation

/// How one delivery went.
public enum RunResult: Sendable, Equatable {
    case delivered
    /// The user switched this connector off.
    case skipped
    /// Called off. Not a failure — nobody is waiting for the result any more,
    /// and a feed outage is a different thing entirely. Anything already put on
    /// the clock was taken back down first.
    case cancelled
    case failed(String)
}

/// One clock's deliveries, one at a time, and how the last runs went.
///
/// The part of the AWTRIX session that is not about any one firmware: the queue
/// that keeps two deliveries off a clock at once, the failure count a backoff
/// is read from, and the one reading of a thrown error that both halves of a
/// run share. A session owns one, and sessions do not share one — a clock that
/// has stopped answering holds up only its own deliveries.
///
/// It never sees a device, a connector or a setting. What it runs is a closure
/// the session hands it, and what it records is keyed by the id the session
/// names.
public actor DeliveryChain {
    private let retryPolicy: RetryPolicy

    /// The last delivery to have claimed a place. Deliveries run one at a time
    /// by waiting on it — see `queued(_:)` for how. Runs and replays share it,
    /// which is the whole point: two chains would be no serialisation at all.
    private var tail: Task<Void, Never>?

    /// Deliveries failed in a row, per connector. An id that is not in here has
    /// none. In memory only: a relaunch is a fresh start, and a connector that
    /// is still down earns its backoff again within a couple of intervals.
    private var failureCounts: [String: Int] = [:]

    public init(retryPolicy: RetryPolicy = RetryPolicy()) {
        self.retryPolicy = retryPolicy
    }

    /// How many runs of this connector have failed in a row.
    public func consecutiveFailures(connectorId: String) -> Int {
        failureCounts[connectorId] ?? 0
    }

    /// How long to wait before the next attempt: the cadence the user chose
    /// while the connector is healthy, a growing backoff while it is failing,
    /// and never longer than that cadence either way.
    ///
    /// Worth being plain about which direction this moves, because "backoff"
    /// suggests the other one: the clip is to the connector's OWN interval, so
    /// a failing connector is retried SOONER than its cadence and decays back
    /// towards it, rather than ever being pushed past it. A blip on a
    /// half-hourly feed is retried in thirty seconds instead of costing the
    /// user half an hour of blank clock; a feed that is genuinely down doubles
    /// its way back to the half hour and settles there. It is the retry
    /// interval that is capped at the cadence, which is what the spec asks for.
    public func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval {
        let failures = consecutiveFailures(connectorId: connectorId)
        guard failures > 0 else { return interval }
        return min(retryPolicy.delay(afterConsecutiveFailures: failures), interval)
    }

    /// A run: it takes its turn, and its outcome is recorded against the
    /// connector.
    public func run(
        for connectorId: String, _ work: @escaping @Sendable () async -> RunResult
    ) async -> RunResult {
        let result = await queued(work)
        // Awaiting a task is not interrupted by cancellation, so this is
        // reached even when the caller gave up — which is the point. A run torn
        // down still has an outcome, and the backoff has to be told it was a
        // cancellation rather than left reading the last failure.
        record(result, for: connectorId)
        return result
    }

    /// A delivery that is not a run — the History's replay. It takes its turn
    /// exactly as a run does and is recorded against nothing: the backoff
    /// describes how the FEED is behaving, and hearing this morning's anecdote
    /// again is not evidence about anekdot.ru in either direction.
    public func deliver(_ work: @escaping @Sendable () async -> RunResult) async -> RunResult {
        await queued(work)
    }

    /// What a thrown error means for the delivery that raised it.
    ///
    /// One reading, shared by the produce and by the delivery, because the two
    /// halves must not classify the same error differently — a connector
    /// throwing `CancellationError` and a notify killed by the same quit are
    /// the same event seen from two places.
    ///
    /// `URLError(.cancelled)` is the transport naming this specific event
    /// rather than the ambient task state: `URLSession` reports a request
    /// killed by its task's cancellation that way, and app quit killing an
    /// in-flight notify is the ordinary producer. As typed as
    /// `CancellationError`, and it cannot swallow a device fault — those arrive
    /// as `AwtrixError.http`, never as a `URLError`.
    public static func classify(_ error: any Error) -> RunResult {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .failed(String(describing: error))
    }

    /// Reads the count off the OUTCOME, not off the path that produced it.
    ///
    /// There are three ways a run ends up `.cancelled` and they arrive from
    /// three different places — a connector throwing `CancellationError`, the
    /// transport reporting `URLError(.cancelled)`, and a delivery that got all
    /// the way through only to find the task torn down. Deciding here, on the
    /// one value all three become, is what stops the next guard added to the
    /// session's `send` from quietly re-classifying one of them.
    private func record(_ result: RunResult, for connectorId: String) {
        switch result {
        case .delivered:
            failureCounts[connectorId] = 0
        case .failed:
            failureCounts[connectorId, default: 0] += 1
        case .cancelled:
            // Not evidence about the feed. The user quitting, a connector
            // switched off mid-delivery, a schedule rebuilt — none of them say
            // whether the source is up. Counting one would back a healthy
            // connector off for having been interrupted; resetting on one would
            // clear a real backoff for the same non-reason.
            break
        case .skipped:
            // Never actually arrives. The session answers `.skipped` from its
            // enablement guard, before there is a run to have an outcome, so
            // this branch exists because the switch is exhaustive and not
            // because it decides anything — a mutation of it changes nothing,
            // and the rule it looks like it implements is pinned on that guard
            // instead. The answer would be the same either way: a connector the
            // user switched off has not failed, and has not recovered either.
            break
        }
    }

    /// Takes a place in the chain, waits for whatever is ahead, and runs `work`
    /// when it gets there.
    ///
    /// Claiming a place is a single actor-isolated step — there is no
    /// suspension between reading `tail` and writing it — so no caller can slip
    /// between the two and take the same place twice.
    ///
    /// Shared by both entry points rather than written twice, because a second
    /// copy is a second chain the moment one of them is edited, and two chains
    /// are no serialisation at all.
    private func queued(
        _ work: @escaping @Sendable () async -> RunResult
    ) async -> RunResult {
        let predecessor = tail
        let claimed = Task { () -> RunResult in
            await predecessor?.value
            // Checked on the far side of the wait. Cancellation cannot break
            // `predecessor?.value`, so without this a delivery cancelled while
            // queued goes on to put a banner up that nobody is waiting for.
            if Task.isCancelled { return .cancelled }
            return await work()
        }
        tail = Task { _ = await claimed.value }

        // `claimed` is unstructured, so it inherits neither the caller's
        // cancellation nor breaks on it when awaited. Forwarded by hand, or a
        // caller that gives up gets neither the work stopped nor itself back.
        return await withTaskCancellationHandler {
            await claimed.value
        } onCancel: {
            claimed.cancel()
        }
    }
}
```

- [ ] **Step 4: Make `ConnectorHost` delegate to the chain**

In `Sources/PixelClockKit/Scheduling/ConnectorHost.swift`:

(a) Delete the `RunResult` enum and its doc comment (`/// How one delivery went.` through its closing brace). It now lives in `DeliveryChain.swift`.

(b) Replace the stored property `private let retryPolicy: RetryPolicy` with nothing, and replace the `tail` and `failureCounts` declarations, doc comments included, with:

```swift
    /// Deliveries one at a time, and how the last runs went. Runs and replays
    /// both take their turn in it — see `runOnce(connectorId:)` for why they
    /// must.
    private let chain: DeliveryChain
```

(c) In `init`, replace `self.retryPolicy = retryPolicy` with `self.chain = DeliveryChain(retryPolicy: retryPolicy)`. The init's signature does not change.

(d) Replace `consecutiveFailures(connectorId:)`, `nextDelay(connectorId:interval:)` and `record(_:for:)`, doc comments included, with:

```swift
    /// How many deliveries this connector has failed in a row.
    public func consecutiveFailures(connectorId: String) async -> Int {
        await chain.consecutiveFailures(connectorId: connectorId)
    }

    /// How long to wait before the next attempt. Answered by the chain,
    /// because the chain is what watched the last runs — see
    /// `DeliveryChain.nextDelay(connectorId:interval:)`.
    public func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval {
        await chain.nextDelay(connectorId: connectorId, interval: interval)
    }
```

(e) In `runOnce(connectorId:)`, keep both guards and the comment above them exactly as they are, and replace everything after `guard store.settings(for: connectorId).isEnabled else { return .skipped }` with:

```swift

        return await chain.run(for: connectorId) { [self] in await produceAndSend(connector) }
    }
```

(The comment that stood between the queued call and `record` now sits in `DeliveryChain.run(for:_:)`.)

(f) Replace the body of `deliver(_:)` (doc comment unchanged) with:

```swift
    public func deliver(_ output: ConnectorOutput) async -> RunResult {
        await chain.deliver { [self] in await send(output, from: nil) }
    }
```

(g) Delete `queued(_:)` with its doc comment.

(h) In `produceAndSend(_:)` and in `send(_:from:)`, replace `return classify(error)` with `return DeliveryChain.classify(error)`, two sites.

(i) Delete `classify(_:)` with its doc comment.

- [ ] **Step 5: Run the new and the moved tests**

Run: `swift test --filter DeliveryChainTests`
Expected: PASS, 6 tests.

Run: `swift test --filter ConnectorHostTests`
Expected: PASS, 53 tests.

Run: `swift test --filter RetryPolicyTests`
Expected: PASS, 11 tests.

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test`
Expected: PASS, `N0 + 6` tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Scheduling/DeliveryChain.swift Sources/PixelClockKit/Scheduling/ConnectorHost.swift Tests/PixelClockKitTests/DeliveryChainTests.swift
git commit -m "refactor: lift the delivery chain out of the connector host"
```

- [ ] **Step 7: Mutation checks — the moved guards are still pinned**

No new guard was added, so no older mutation needs re-running. Each mutation below goes in on its own and is reverted with `git restore <file>` before the next. Run the named filter; every listed test must go red.

| # | Site | Mutation | Filter | Must fail |
| --- | --- | --- | --- | --- |
| M1.1 | `DeliveryChain.queued` | delete `if Task.isCancelled { return .cancelled }` | `ConnectorHostTests\|DeliveryChainTests` | `cancellingAQueuedRunStopsItBeforeItReachesTheDevice`, `workCancelledWhileQueuedNeverStarts` |
| M1.2 | `DeliveryChain.queued` | replace the `withTaskCancellationHandler { … } onCancel: { … }` with `await claimed.value` | `ConnectorHostTests\|DeliveryChainTests` | `cancellingARunStopsTheConnectorAndReportsCancelled`, `aCallerThatGivesUpCancelsTheWorkItWasWaitingFor` |
| M1.3 | `DeliveryChain.queued` | delete `tail = Task { _ = await claimed.value }` | `ConnectorHostTests\|DeliveryChainTests` | `twoRunsDoNotOverlapOnTheDevice`, `aReplayWaitsForARunInFlightRatherThanOverlapping`, `theChainRunsOnePieceOfWorkAtATime` |
| M1.4 | `DeliveryChain.record` | `case .cancelled: break` → `failureCounts[connectorId, default: 0] += 1` | `RetryPolicyTests\|ConnectorHostTests\|DeliveryChainTests` | `aCancelledRunLeavesTheFailureCountWhereItWas`, `aRunTornDownAfterItReachedTheDeviceLeavesTheFailureCountWhereItWas`, `aRunsOutcomeIsCountedAndADeliverysIsNot` |
| M1.5 | `DeliveryChain.run` | delete `record(result, for: connectorId)` | `RetryPolicyTests\|DeliveryChainTests` | `hostCountsConsecutiveFailuresAndResetsOnSuccess`, `aRunsOutcomeIsCountedAndADeliverysIsNot` |
| M1.6 | `DeliveryChain.nextDelay` | `min(…, interval)` → `retryPolicy.delay(afterConsecutiveFailures: failures)` | `RetryPolicyTests\|DeliveryChainTests` | `theBackoffNeverWaitsLongerThanTheConnectorsOwnInterval`, `theBackoffIsClippedToTheCadence` |
| M1.7 | `DeliveryChain.classify` | delete the `URLError` line | `RetryPolicyTests\|ConnectorHostTests\|DeliveryChainTests` | `aRequestKilledByCancellationIsNotAFailedRun`, `aRequestKilledByCancellationLeavesTheFailureCountWhereItWas`, `onlyACancellationIsReadAsOne` |
| M1.8 | `ConnectorHost.deliver` | `chain.deliver { … }` → `chain.run(for: "stub") { … }` | `ConnectorHostTests` | `aReplayDoesNotAdvanceTheFailureCounter` |

Run each as `swift test --filter '<filter>'`. After the last one, `git status --short` must print nothing.

---

### Task 2: The connector host is the AWTRIX clock's session

A pure rename and move. No behaviour or test body changes, so this task has no failing test: the proof is the same test count before and after, and no old name left.

**Files:**
- Move: `Sources/PixelClockKit/Scheduling/ConnectorHost.swift` → `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`
- Move: `Tests/PixelClockKitTests/ConnectorHostTests.swift` → `Tests/PixelClockKitTests/AwtrixClockSessionTests.swift`
- Modify (moved protocols): `Sources/PixelClockKit/Audio/SequentialAudioPlayer.swift` (gains `AudioPlaying`), `Sources/PixelClockKit/Device/CatalogueIconInstaller.swift` (gains `IconInstalling`), `Sources/PixelClockKit/Connectors/Connector.swift` (gains `ConnectorMaintaining`, `MaintenanceResult`)
- Modify (rename only): every file that names `ConnectorHost`: `Sources/PixelClockKit/Connectors/WeatherConnector.swift:16`, `Sources/PixelClockKit/Audio/SequentialAudioPlayer.swift:27`, `Sources/PixelClockKit/Scheduling/RetryPolicy.swift:13`, `Sources/PixelClockTilesApp/QuitBudget.swift:18`, `Sources/PixelClockTilesApp/AppModel.swift:14,38,430,596,961,1829`, `Tests/PixelClockKitTests/WeatherConnectorTests.swift:130,137`, `Tests/PixelClockKitTests/RetryPolicyTests.swift:7,22,23,42`, `Tests/PixelClockKitTests/AnecdoteConnectorTests.swift:620,623`, `Tests/PixelClockKitTests/AwtrixClockSessionTests.swift` (the moved file), `Tests/PixelClockTilesAppTests/AppShellTests.swift:213,359`, `Tests/PixelClockTilesAppTests/AppModelTests.swift:1334`, `Tests/PixelClockTilesAppTests/Doubles.swift:631,660,712,820,825`

**Interfaces:**
- Consumes: Task 1's `DeliveryChain`.
- Produces: `public actor AwtrixClockSession` with exactly `ConnectorHost`'s API —
  - `init(device: AwtrixDevice, registry: ConnectorRegistry, store: any SettingsStore, audio: any AudioPlaying, iconInstaller: any IconInstalling, retryPolicy: RetryPolicy = RetryPolicy(), borrowedOverlays: any BorrowedOverlayStore = InMemoryBorrowedOverlayStore())`
  - `runOnce(connectorId:) async -> RunResult`, `deliver(_:) async -> RunResult`, `maintain(connectorId:) async -> MaintenanceResult`, `nextDelay(connectorId:interval:) async -> TimeInterval`, `consecutiveFailures(connectorId:) async -> Int`, `restoreDeviceState(borrowedBy:) async`
  - `extension AwtrixClockSession: ConnectorRunning {}` in `AppModel.swift`.
- Production caller: `AppModel.live()` (`host: AwtrixClockSession(…)`).

- [ ] **Step 1: Confirm the starting point**

Run: `swift test --filter ConnectorHostTests 2>&1 | tail -1`
Expected: PASS, 53 tests.

- [ ] **Step 2: Move the files**

```bash
mkdir -p Sources/PixelClockKit/Awtrix
git mv Sources/PixelClockKit/Scheduling/ConnectorHost.swift Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift
git mv Tests/PixelClockKitTests/ConnectorHostTests.swift Tests/PixelClockKitTests/AwtrixClockSessionTests.swift
```

- [ ] **Step 3: Rename every mention**

```bash
grep -rlE 'ConnectorHost' Sources Tests \
  | xargs perl -pi -e 's/\bConnectorHostTests\b/AwtrixClockSessionTests/g; s/\bConnectorHost\b/AwtrixClockSession/g'
```

Run: `grep -rn "ConnectorHost" Sources Tests`
Expected: no output.

- [ ] **Step 4: Move the model-neutral vocabulary out of the session file**

Cut each block below from `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`, doc comment included, and paste it unchanged at the named place:

- `public protocol AudioPlaying` (with `/// Plays prepared audio on the Mac. …`) → `Sources/PixelClockKit/Audio/SequentialAudioPlayer.swift`, directly after `import Foundation`, followed by one blank line.
- `public protocol IconInstalling` → `Sources/PixelClockKit/Device/CatalogueIconInstaller.swift`, directly after `import Foundation`, followed by one blank line.
- `public protocol ConnectorMaintaining` (with `/// Work a connector does away from the delivery path. …`) and `public enum MaintenanceResult` (with `/// How one background pass went. …`) → the end of `Sources/PixelClockKit/Connectors/Connector.swift`, each preceded by one blank line.

After the cut, `AwtrixClockSession.swift` is `import Foundation`, then the actor.

- [ ] **Step 5: Say what the session is**

Replace the actor's doc comment (`/// Owns everything a connector must not care about: enablement, delivery to the` / `/// device, and containment of failures.`) with:

```swift
/// The AWTRIX clock's session: everything a connector must not care about —
/// enablement, delivery to the device, custody of what was borrowed, and
/// containment of failures — for the one clock this app drives.
///
/// Its deliveries take their turn in a `DeliveryChain`, which is what keeps two
/// of them off the clock at once and what the backoff is read from. What stays
/// here is what only an AWTRIX clock has: the notify and custom-app payloads,
/// the held banner and its release, the icon installer, and `DeviceCustody`.
```

- [ ] **Step 6: Run the suite**

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test --filter AwtrixClockSessionTests`
Expected: PASS, 53 tests, the same 53 as in Step 1.

Run: `swift test`
Expected: PASS, `N0 + 6` tests.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: the connector host becomes the AWTRIX clock's session"
```

---

### Task 3: A delivery carries a scene, and the audio travels beside it

`ConnectorOutput` becomes `Delivery<AwtrixScene>`, spelled `AwtrixDelivery`. Everything the clock draws or sounds (text, icon, bar, jingle, surface, lifetime, overlay) moves into `AwtrixScene`. What the Mac plays stays on the delivery: `localAudio`, and the `holdUntilAudioEnds` that waits for it. The convenience initializer takes `ConnectorOutput`'s labels in `ConnectorOutput`'s order, and `@dynamicMemberLookup` reads scene fields straight off the delivery, so every producer and every assertion reads the same after a type rename.

The risk is one this project has already paid for once: a field that exists on both sides of a crossing and is never copied across it (`aProgressBarReachesTheDeviceOnAnAppDelivery`). The mutation step goes after exactly that.

**Files:**
- Create: `Sources/PixelClockKit/Connectors/Delivery.swift`
- Create: `Sources/PixelClockKit/Awtrix/AwtrixScene.swift`
- Modify: `Sources/PixelClockKit/Connectors/Connector.swift` (delete `IconReference`, `DeliverySurface`, `ProgressBar`, `ConnectorOutput`; `produce()` return type)
- Modify (rename only): `Sources/PixelClockKit/Connectors/WeatherConnector.swift`, `ClaudeUsageConnector.swift`, `AnecdoteConnector.swift`, `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`, `Sources/PixelClockTilesApp/AppModel.swift` (L22 `deliver`, L54 `output(for:)`)
- Modify (rename only): `Tests/PixelClockKitTests/AwtrixClockSessionTests.swift` (38), `ConnectorRegistryTests.swift` (6), `VoiceCasterTests.swift` (2), `Tests/PixelClockTilesAppTests/Doubles.swift` (8), `AppShellTests.swift` (3)
- Test: `Tests/PixelClockKitTests/AwtrixDeliveryTests.swift` (new)

**Interfaces:**
- Consumes: `DeviceOverlay` (`enum DeviceOverlay: String, Sendable, Equatable, CaseIterable`), `SpokenClip`.
- Produces:
  - `@dynamicMemberLookup public struct Delivery<Scene: Sendable & Equatable>: Sendable, Equatable` — `var scene: Scene`, `var localAudio: [SpokenClip]`, `var holdUntilAudioEnds: Bool`, `init(scene:localAudio:holdUntilAudioEnds:)`, `subscript<Value>(dynamicMember: KeyPath<Scene, Value>) -> Value`
  - `public struct AwtrixScene: Sendable, Equatable` — `text`, `icon`, `progress`, `jingle`, `duration`, `color`, `surface`, `lifetime`, `overlay`
  - `public typealias AwtrixDelivery = Delivery<AwtrixScene>`
  - `extension Delivery where Scene == AwtrixScene { public init(text:icon:progress:jingle:localAudio:holdUntilAudioEnds:duration:color:surface:lifetime:overlay:) }`
  - `IconReference`, `DeliverySurface`, `ProgressBar` — moved, unchanged.
  - `Connector.produce() async throws -> AwtrixDelivery`; `AwtrixClockSession.deliver(_ output: AwtrixDelivery)`; `ConnectorRunning.deliver(_ output: AwtrixDelivery)`; `AnecdoteReplaying.output(for:) -> AwtrixDelivery`.
- Production callers: the three connectors build `AwtrixDelivery(…)`; the session's `send` reads `output.text`/`.icon`/… through the lookup and `output.localAudio`/`.holdUntilAudioEnds` directly; `AppModel.replay(_:)` passes an `AwtrixDelivery` to `host.deliver`.

**Proven template:** `ConnectorOutput` itself. Same fields, labels and defaults, split along the line the spec draws.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/AwtrixDeliveryTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// What a face hands the AWTRIX session. The clock draws the scene; the Mac
// plays the audio. The buzzer is the clock's own sound, so a jingle is part of
// what the clock is asked to show.

@Test func theSoundTravelsBesideTheSceneRatherThanInsideIt() {
    let clip = SpokenClip(url: URL(fileURLWithPath: "/tmp/a.wav"))

    let delivery = AwtrixDelivery(
        text: "hi", jingle: "nokia:d=4,o=5,b=225:8e6",
        localAudio: [clip], holdUntilAudioEnds: true
    )

    #expect(delivery.localAudio == [clip])
    #expect(delivery.holdUntilAudioEnds)
    #expect(delivery.scene.text == "hi")
    #expect(delivery.scene.jingle == "nokia:d=4,o=5,b=225:8e6")
}

// Every field a producer can name reaches the scene. This is the crossing the
// progress bar once failed to make — green on both banks, nothing crossing.
@Test func aDeliveryReadsAsTheSceneItCarries() {
    let delivery = AwtrixDelivery(
        text: "83%",
        icon: .bundled("ClaudeStar"),
        progress: ProgressBar(percent: 83, fill: "#FFD24A", track: "#303030"),
        duration: 10,
        color: "#D97757",
        surface: .app("claude"),
        lifetime: 900,
        overlay: .rain
    )

    #expect(delivery.text == "83%")
    #expect(delivery.icon == .bundled("ClaudeStar"))
    #expect(delivery.progress == ProgressBar(percent: 83, fill: "#FFD24A", track: "#303030"))
    #expect(delivery.duration == 10)
    #expect(delivery.color == "#D97757")
    #expect(delivery.surface == .app("claude"))
    #expect(delivery.lifetime == 900)
    #expect(delivery.overlay == .rain)
    #expect(delivery.text == delivery.scene.text)
}

// A producer that names only its text gets a banner and nothing else — the
// defaults every output had before there was a scene.
@Test func aDeliveryThatNamesOnlyItsTextIsAPlainBanner() {
    let delivery = AwtrixDelivery(text: "plain")

    #expect(delivery.surface == .notification)
    #expect(delivery.icon == nil)
    #expect(delivery.progress == nil)
    #expect(delivery.jingle == nil)
    #expect(delivery.duration == nil)
    #expect(delivery.color == nil)
    #expect(delivery.lifetime == nil)
    #expect(delivery.overlay == nil)
    #expect(delivery.localAudio.isEmpty)
    #expect(delivery.holdUntilAudioEnds == false)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AwtrixDeliveryTests`
Expected: FAIL at compile time — `cannot find 'AwtrixDelivery' in scope`.

- [ ] **Step 3: Create `Delivery.swift`**

```swift
// Sources/PixelClockKit/Connectors/Delivery.swift
import Foundation

/// What a face hands a clock's session: the scene to draw, and the sound that
/// goes with it.
///
/// Generic over the scene because every clock model draws in its own
/// vocabulary. An AWTRIX scene cannot be handed to a TC002 session, and the
/// type is what says so. The audio is not part of any scene: the Mac plays it,
/// not the clock, and which clock a tile is on does not decide where its sound
/// comes out.
///
/// `@dynamicMemberLookup` so a delivery reads as the scene it carries —
/// `delivery.text` is `delivery.scene.text`. Read-only: a face builds a
/// delivery whole, and nothing patches one on its way to the clock.
@dynamicMemberLookup
public struct Delivery<Scene: Sendable & Equatable>: Sendable, Equatable {
    public var scene: Scene
    /// Played on the Mac, strictly after the scene is on the clock.
    public var localAudio: [SpokenClip]
    /// Keep the banner on the clock until the audio finishes, rather than for a
    /// fixed duration. The producer knows how long it will speak; the host does
    /// not, and guessing a scroll count was worse.
    public var holdUntilAudioEnds: Bool

    public init(scene: Scene, localAudio: [SpokenClip] = [], holdUntilAudioEnds: Bool = false) {
        self.scene = scene
        self.localAudio = localAudio
        self.holdUntilAudioEnds = holdUntilAudioEnds
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<Scene, Value>) -> Value {
        scene[keyPath: keyPath]
    }
}
```

- [ ] **Step 4: Create `AwtrixScene.swift`**

`IconReference`, `DeliverySurface` and `ProgressBar` are **cut** from `Connector.swift` and pasted here unchanged, doc comments included (the `IconReference` comment keeps phase 0's `enum PixelClockKit` wording). They are shown in full so the file is complete. The field doc comments on `AwtrixScene` are `ConnectorOutput`'s own.

```swift
// Sources/PixelClockKit/Awtrix/AwtrixScene.swift
import Foundation

/// Spelled out rather than `IconRef`: LaunchServices publicly declares
/// `typedef struct OpaqueIconRef* IconRef`, so that name is ambiguous in any
/// file reaching CoreServices — which is every file in the app target and every
/// file in the test target. Module qualification cannot rescue it either,
/// because this module declares an `enum PixelClockKit` that shadows its own
/// name.
public enum IconReference: Sendable, Equatable {
    /// Already present on the device, referenced by basename.
    ///
    /// The one case that promises nothing: it names a file this app never put
    /// there and cannot put back. Right for art a user placed on their own
    /// flash, wrong for anything this app draws by itself — on a clock that has
    /// been reset the picture is simply gone, and a banner with no icon beside
    /// it reads as ordinary.
    case installed(String)
    /// Fetched from the LaMetric catalogue by id, then installed.
    case catalogue(Int)
    /// Art shipped inside this app, uploaded to the flash on demand.
    ///
    /// The case for a picture the catalogue does not have. It installs by
    /// exactly the same route as `catalogue` — list, skip or upload — and
    /// differs only in where the bytes come from, so it keeps the same promise
    /// on a clock that has never seen this app.
    case bundled(String)
}

/// Where an output is drawn on the clock.
///
/// Two surfaces, and they are not settings of one thing. A notification
/// interrupts whatever the loop is showing and then goes away; an app IS the
/// loop, and stays there until it is replaced or removed. An anecdote is an
/// interruption; the weather is ambient and should be there when you glance at
/// the clock. The two coexist without arbitration — a notification draws over
/// the loop, which is exactly what it is for.
public enum DeliverySurface: Sendable, Equatable {
    case notification
    /// An app in the device's own loop, under this name.
    case app(String)
}

/// A bar filled from the left under an app's text.
///
/// Named for what the firmware calls it — `progress`, and not `bar`, which is a
/// different field drawing a little graph of a series. The percentage is what
/// the device draws rather than what is true: a reading past a hundred belongs
/// in the text, where it can be read, and not in a bar that has no room for it.
public struct ProgressBar: Sendable, Equatable {
    /// Nought to a hundred, clamped on the way in — the firmware has nothing to
    /// draw outside that and does not say so.
    public let percent: Int
    public let fill: String
    public let track: String

    public init(percent: Int, fill: String, track: String) {
        self.percent = min(100, max(0, percent))
        self.fill = fill
        self.track = track
    }
}

/// What an AWTRIX clock is asked to show for one delivery.
///
/// Everything the clock itself draws or sounds — the buzzer's jingle included.
/// The Mac's speech is not here; it rides on the `Delivery` beside the scene.
///
/// A struct with a `surface` rather than one case per surface, so a scene can
/// carry a field its surface ignores, and the session is what drops it. The
/// session's tests pin that a lifetime on a notification never reaches the
/// firmware.
public struct AwtrixScene: Sendable, Equatable {
    public var text: String
    public var icon: IconReference?
    /// The bar drawn under the text, or nil for an output that is only words.
    public var progress: ProgressBar?
    public var jingle: String?
    public var duration: Int?
    public var color: String?
    /// Where this is drawn. Defaulted to the notification, which is what every
    /// output was before there was a choice.
    public var surface: DeliverySurface
    /// Seconds without a fresh delivery after which the clock takes this off
    /// itself, or nil to stay until this app removes it.
    ///
    /// Next to `surface` because it belongs to one: an app in the loop is the
    /// only thing that outlives the delivery that made it. Defaulted to none,
    /// so a producer that says nothing about staleness behaves exactly as it
    /// did before there was anything to say.
    public var lifetime: Int?
    /// The device-wide weather layer this output wants, or nil to leave
    /// whatever is on the device alone.
    ///
    /// Carried on the output rather than written by the connector, because a
    /// connector produces and returns and never talks to the device. It is
    /// global state with one borrower and a value to put back afterwards, which
    /// is `DeviceCustody`'s job and not a producer's.
    public var overlay: DeviceOverlay?

    public init(
        text: String,
        icon: IconReference? = nil,
        progress: ProgressBar? = nil,
        jingle: String? = nil,
        duration: Int? = nil,
        color: String? = nil,
        surface: DeliverySurface = .notification,
        lifetime: Int? = nil,
        overlay: DeviceOverlay? = nil
    ) {
        self.text = text
        self.icon = icon
        self.progress = progress
        self.jingle = jingle
        self.duration = duration
        self.color = color
        self.surface = surface
        self.lifetime = lifetime
        self.overlay = overlay
    }
}

/// What an AWTRIX face produces and the AWTRIX session delivers.
public typealias AwtrixDelivery = Delivery<AwtrixScene>

extension Delivery where Scene == AwtrixScene {
    /// Everything an AWTRIX delivery can say, in the labels and the order the
    /// connectors have always used.
    public init(
        text: String,
        icon: IconReference? = nil,
        progress: ProgressBar? = nil,
        jingle: String? = nil,
        localAudio: [SpokenClip] = [],
        holdUntilAudioEnds: Bool = false,
        duration: Int? = nil,
        color: String? = nil,
        surface: DeliverySurface = .notification,
        lifetime: Int? = nil,
        overlay: DeviceOverlay? = nil
    ) {
        self.init(
            scene: AwtrixScene(
                text: text,
                icon: icon,
                progress: progress,
                jingle: jingle,
                duration: duration,
                color: color,
                surface: surface,
                lifetime: lifetime,
                overlay: overlay
            ),
            localAudio: localAudio,
            holdUntilAudioEnds: holdUntilAudioEnds
        )
    }
}
```

- [ ] **Step 5: Remove the old output from `Connector.swift`**

In `Sources/PixelClockKit/Connectors/Connector.swift`, delete everything from the `IconReference` doc comment (`` /// Spelled out rather than `IconRef`: … ``) through the closing brace of `public struct ConnectorOutput`. That is four declarations: `IconReference`, `DeliverySurface`, `ProgressBar`, `ConnectorOutput`. `SpokenClip` above them stays.

- [ ] **Step 6: Rename the type everywhere else**

```bash
grep -rlw 'ConnectorOutput' Sources Tests | xargs perl -pi -e 's/\bConnectorOutput\b/AwtrixDelivery/g'
```

Run: `grep -rnw "ConnectorOutput" Sources Tests`
Expected: no output.

This one command reaches: the protocol requirement `func produce() async throws -> AwtrixDelivery`, the three connectors' `produce()` return types and constructors, `AnecdoteConnector.output(for:)`, the session's `deliver(_ output: AwtrixDelivery)` and `send(_ output: AwtrixDelivery, from:)`, `ConnectorRunning.deliver` (AppModel L22), `AnecdoteReplaying.output(for:)` (AppModel L54), and every test double and arrange line. The body of `send` does not change: it reads `output.text`, `output.icon`, `output.surface`, `output.lifetime`, `output.progress`, `output.overlay`, `output.jingle`, `output.duration` and `output.color` through the lookup, and `output.localAudio` and `output.holdUntilAudioEnds` directly.

- [ ] **Step 7: Run the tests**

Run: `swift test --filter AwtrixDeliveryTests`
Expected: PASS, 3 tests.

Run: `swift test --filter 'AwtrixClockSessionTests|ConnectorRegistryTests|WeatherConnectorTests|ClaudeUsageTests|AnecdoteConnectorTests|VoiceCasterTests'`
Expected: PASS, with the same per-file counts as before this task (at `39d7072`: 53 + 10 + 30 + 14 + 44 + 26 = 177; lane C may have changed `ClaudeUsageTests`' count since).

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test`
Expected: PASS, `N0 + 9` tests.

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: a delivery carries an AWTRIX scene, and the audio travels beside it"
```

- [ ] **Step 9: Mutation checks — nothing is lost crossing into the scene**

All in the convenience initializer in `AwtrixScene.swift`, one at a time, each reverted with `git restore Sources/PixelClockKit/Awtrix/AwtrixScene.swift`.

| # | Mutation | Filter | Must fail |
| --- | --- | --- | --- |
| M3.1 | `progress: progress` → `progress: nil` in the `AwtrixScene(…)` call | `AwtrixClockSessionTests\|AwtrixDeliveryTests\|ClaudeUsageTests` | `aProgressBarReachesTheDeviceOnAnAppDelivery`, `aDeliveryReadsAsTheSceneItCarries`, `theAppDrawsThePercentageInTheBrandColourOverABandedBar` |
| M3.2 | `overlay: overlay` → `overlay: nil` | `WeatherConnectorTests\|AwtrixDeliveryTests` | `theWeatherIsDrawnInTheClocksOwnLoopRatherThanOverIt`, `theOverlayTheWeatherAsksForIsWrittenToTheDevice`, `aDeliveryReadsAsTheSceneItCarries` |
| M3.3 | `lifetime: lifetime` → `lifetime: nil` | `AwtrixClockSessionTests\|WeatherConnectorTests` | `aLifetimeReachesTheDeviceOnAnAppDelivery`, `theReadingIsGivenAnHourBeforeTheClockDropsIt` |
| M3.4 | `holdUntilAudioEnds: holdUntilAudioEnds` → `holdUntilAudioEnds: false` | `AwtrixClockSessionTests\|AwtrixDeliveryTests` | `aHeldBannerStaysUpForTheAudioAndIsDismissedAfterwards`, `theSoundTravelsBesideTheSceneRatherThanInsideIt` |
| M3.5 | default `surface: DeliverySurface = .notification` → `.app("stray")` in the `Delivery` extension's initializer | `AwtrixClockSessionTests\|AwtrixDeliveryTests` | `runOnceDeliversTextToTheDevice`, `aDeliveryThatNamesOnlyItsTextIsAPlainBanner` |
| M3.6 | `jingle: jingle` → `jingle: nil` | `AwtrixClockSessionTests\|AnecdoteConnectorTests` | `runOnceSendsTheJingleAlongsideTheText`, `runOnceStillDeliversWhatItProduced` |

After the last one, `git status --short` must print nothing.

---

### Task 4: A connector reads, and its face draws

The protocol gains `associatedtype Reading`, `read()` and `awtrixFace`. Its `produce()` requirement becomes an extension method that draws what was read. Each connector's former `produce()` splits along the line `ClaudeUsageConnector` already had: the fetch becomes `read()`, and the drawing is a static or instance `output(for:)` that the face wraps. Test doubles whose reading already is a delivery get a pass-through face from a test-only extension, so each double changes by one method name.

**Files:**
- Create: `Sources/PixelClockKit/Awtrix/AwtrixFace.swift`
- Modify: `Sources/PixelClockKit/Connectors/Connector.swift` (protocol members; `produce()` extension)
- Modify: `Sources/PixelClockKit/Connectors/WeatherConnector.swift` (L71–73 comment, L80–114 `produce()` → `read()`, `awtrixFace`, `output(for:)`)
- Modify: `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` (L57–62 `produce()` → `read()`, `awtrixFace`; L76–80 doc)
- Modify: `Sources/PixelClockKit/Connectors/AnecdoteConnector.swift` (L270–289 `produce()` → `read()`, `awtrixFace`)
- Modify: `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift` (`produceAndSend` doc comment only)
- Modify (doubles: `produce()` → `read()`): `Tests/PixelClockKitTests/AwtrixClockSessionTests.swift` (`StubConnector`, `GatedConnector`, `CountingConnector`, `BlockingConnector`, `SpyMaintainingConnector`), `ConnectorRegistryTests.swift` (`FakeConnector`), `VoiceCasterTests.swift` (`NarratedConnector`, `UnnarratedConnector`), `Tests/PixelClockTilesAppTests/Doubles.swift` (`StubConnector`, `BrokenConnector`)
- Create: `Tests/PixelClockKitTests/PassThroughFace.swift`, `Tests/PixelClockTilesAppTests/PassThroughFace.swift`
- Test: `Tests/PixelClockKitTests/ConnectorFaceTests.swift` (new)

**Interfaces:**
- Consumes: Task 3's `AwtrixDelivery`; `OpenMeteoSource.reading(at:) async throws -> WeatherReading`; `ClaudeUsageReporting.read() async throws -> ClaudeUsageReading?`; `AnecdoteQueue.retire(_:)`; `AnecdoteConnector.output(for:) -> AwtrixDelivery`; `ClaudeUsageConnector.output(for:) -> AwtrixDelivery`.
- Produces:
  - `public struct AwtrixFace<Reading: Sendable>: Sendable` — `init(_ render: @escaping @Sendable (Reading) -> AwtrixDelivery)`, `func draw(_ reading: Reading) -> AwtrixDelivery`
  - `protocol Connector` — `associatedtype Reading: Sendable`, `func read() async throws -> Reading`, `var awtrixFace: AwtrixFace<Reading> { get }`; `produce()` is no longer a requirement
  - `extension Connector { public func produce() async throws -> AwtrixDelivery }`
  - `WeatherConnector.read() async throws -> WeatherReading`, `WeatherConnector.awtrixFace`, `static func output(for reading: WeatherReading) -> AwtrixDelivery`
  - `ClaudeUsageConnector.read() async throws -> ClaudeUsageReading`, `ClaudeUsageConnector.awtrixFace`
  - `AnecdoteConnector.read() async throws -> PreparedAnecdote`, `AnecdoteConnector.awtrixFace`
- Production callers: `AwtrixClockSession.produceAndSend(_:)` calls `connector.produce()`, which calls `read()` and `awtrixFace.draw(_:)`. `AppModel.replay(_:)` keeps calling `AnecdoteConnector.output(for:)` through `AnecdoteReplaying`.

**Proven template:** `ClaudeUsageConnector`, whose `produce()` already fetched a value and handed it to a static `output(for:)`. Weather and anecdotes follow it.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/ConnectorFaceTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// A connector is two halves. `read()` goes out for a value, and its AWTRIX face
// draws that value without going anywhere. `produce()` joins the two, and it is
// what the AWTRIX session runs.

/// Reads a number and draws it, so the join can be seen without a real source.
private struct Numeral: Connector {
    let id = "numeral"
    let displayName = "Numeral"
    let defaultInterval: TimeInterval = 60
    let value: Int

    func read() async throws -> Int { value }

    var awtrixFace: AwtrixFace<Int> { AwtrixFace { AwtrixDelivery(text: "\($0)") } }
}

@Test func whatIsProducedIsWhatTheFaceDrawsOfWhatWasRead() async throws {
    #expect(try await Numeral(value: 42).produce().text == "42")
}

// MARK: - Weather

private let skyAtFourDegrees = Data("""
{"current":{"time":"2026-08-19T02:45","interval":900,"weather_code":61,
  "is_day":1,"precipitation":0.4,"temperature_2m":4.2,"wind_speed_10m":9.0}}
""".utf8)

@Test func theWeatherReadsTheSkyAndItsFaceDrawsIt() async throws {
    let transport = RecordingTransport()
    transport.body = skyAtFourDegrees
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport),
        location: { Coordinates(latitude: 55.7558, longitude: 37.6173) }
    )

    let reading = try await connector.read()
    let drawn = connector.awtrixFace.draw(reading)

    #expect(reading.code == 61)
    #expect(reading.temperature == 4.2)
    #expect(drawn == WeatherConnector.output(for: reading))
    #expect(drawn.text == "4°C")
    #expect(drawn.surface == .app(WeatherConnector.appName))
}

// MARK: - Claude usage

/// Answers with one fixed reading. Stands behind `ClaudeUsageReporting`, the
/// seam the Claude connector's `read()` calls whatever source is behind it.
private struct Reports: ClaudeUsageReporting {
    let reading: ClaudeUsageReading?
    func read() async throws -> ClaudeUsageReading? { reading }
}

@Test func theClaudeReadingIsTheReportersOwnAndItsFaceDrawsIt() async throws {
    let reported = ClaudeUsageReading(utilization: 42, resetsAt: nil)
    let connector = ClaudeUsageConnector(reporter: Reports(reading: reported))

    let reading = try await connector.read()

    #expect(reading == reported)
    #expect(connector.awtrixFace.draw(reading) == ClaudeUsageConnector.output(for: reading))
}

@Test func aClosedGateStopsTheClaudeReadBeforeAnythingIsDrawn() async {
    let connector = ClaudeUsageConnector(
        reporter: Reports(reading: ClaudeUsageReading(utilization: 42, resetsAt: nil)),
        showsNow: { false }
    )

    await #expect(throws: ClaudeUsageConnector.Failure.outOfFocus) {
        _ = try await connector.read()
    }
}

// MARK: - Anecdotes

private let oneAnecdote = """
<rss><channel><item>
<description><![CDATA[Звонок от курьера:<br>- Я подъехал...<br>- Но я вас не вижу...]]></description>
<guid>https://www.anekdot.ru/id/1/</guid>
</item></channel></rss>
"""

// Reading an anecdote is playing it: the read retires it, so a replay that
// draws from the History spends nothing.
@Test func readingAnAnecdoteRetiresItAndItsFaceDrawsTheBanner() async throws {
    let transport = RecordingTransport()
    transport.body = Data(oneAnecdote.utf8)
    let queue = AnecdoteQueue(
        storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("face-\(UUID().uuidString).json"),
        clipRoot: FileManager.default.temporaryDirectory,
        retention: 10 * 24 * 60 * 60
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let anecdote = try await connector.read()

    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(connector.awtrixFace.draw(anecdote) == connector.output(for: anecdote))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ConnectorFaceTests`
Expected: FAIL at compile time — `type 'Numeral' does not conform to protocol 'Connector'`, and `value of type 'WeatherConnector' has no member 'read'`.

- [ ] **Step 3: Create `AwtrixFace.swift`**

```swift
// Sources/PixelClockKit/Awtrix/AwtrixFace.swift
import Foundation

/// How one connector's reading looks on an AWTRIX clock.
///
/// A value rather than a method, so a connector's faces are things it HAS: the
/// TC002's face joins beside this one as a second property, and the models a
/// connector supports are the faces it carries. A pure function — it reaches no
/// network and no device, which is what lets every drawing be tested against a
/// value.
public struct AwtrixFace<Reading: Sendable>: Sendable {
    private let render: @Sendable (Reading) -> AwtrixDelivery

    public init(_ render: @escaping @Sendable (Reading) -> AwtrixDelivery) {
        self.render = render
    }

    public func draw(_ reading: Reading) -> AwtrixDelivery {
        render(reading)
    }
}
```

- [ ] **Step 4: Split the protocol**

In `Sources/PixelClockKit/Connectors/Connector.swift`:

(a) Replace the protocol's doc comment `/// A source of content. Produces and returns; never talks to the device.` with:

```swift
/// A source of content. Reads and returns; never talks to a clock.
///
/// Two halves. `read()` goes out for a value — a feed, a service, a queue —
/// and `awtrixFace` draws that value for an AWTRIX clock without going
/// anywhere. Kept apart so every drawing can be tested against a value, and so
/// another clock model gets a face of its own over the same reading.
```

(b) Directly after `public protocol Connector: Sendable {`, insert:

```swift
    /// What `read()` hands the faces.
    associatedtype Reading: Sendable

```

(c) Replace the last requirement, `func produce() async throws -> AwtrixDelivery`, with:

```swift
    /// Goes out for the value this connector shows. May throw; never draws.
    func read() async throws -> Reading
    /// How the reading looks on an AWTRIX clock.
    var awtrixFace: AwtrixFace<Reading> { get }
```

(d) At the end of the existing `extension Connector { … }` block, after the `isAmbient` default, insert:

```swift

    /// What the AWTRIX session delivers for this connector: the reading,
    /// drawn.
    ///
    /// The one place the two halves meet, so a reading never reaches a clock
    /// undrawn and a face never draws without a fresh reading. A connector
    /// whose read spends something — the anecdotes retire what they pop —
    /// spends it exactly once per delivery.
    public func produce() async throws -> AwtrixDelivery {
        awtrixFace.draw(try await read())
    }
```

- [ ] **Step 5: Split the weather connector**

In `Sources/PixelClockKit/Connectors/WeatherConnector.swift`:

(a) In the doc comment on `private let location`, replace `/// Read on every produce rather than held, so a location typed into the` with `/// Read on every read rather than held, so a location typed into the`.

(b) Replace the whole `public func produce() async throws -> AwtrixDelivery { … }` (L80–114) with the following. The comments inside `output(for:)` are the ones `produce()` carried, unchanged:

```swift
    /// Goes out for the sky where the clock is. Nothing is drawn here; see
    /// `output(for:)`.
    public func read() async throws -> WeatherReading {
        try await source.reading(at: location())
    }

    public var awtrixFace: AwtrixFace<WeatherReading> {
        AwtrixFace { Self.output(for: $0) }
    }

    /// What a reading looks like on the matrix.
    ///
    /// Separated from `read()` so the drawing can be tested against a reading
    /// rather than against a network, as `ClaudeUsageConnector.output(for:)`
    /// already is.
    static func output(for reading: WeatherReading) -> AwtrixDelivery {
        let theme = WeatherTheme(code: reading.code, isDay: reading.isDay)
        // Two quantities in one element: the digits are the AIR temperature,
        // which is what a thermometer would agree with, and the colour is what
        // that feels like. Collapsing them — showing the apparent temperature —
        // gains one number and loses the other. Falling back to the air
        // temperature when the service omitted the felt one, because a reading
        // with no colour is drawn in whatever the previous app left behind.
        let felt = reading.apparentTemperature ?? reading.temperature
        return AwtrixDelivery(
            text: Self.degrees(reading.temperature),
            // The sky, drawn inside the app rather than over the whole matrix.
            // The overlay below already carries it to the device, but four
            // skies share `clear` there and night is not a layer at all — so on
            // an overcast evening the clock shows a number and nothing else.
            // The icon is what distinguishes the eleven, in the eight pixels next
            // to the reading they belong to.
            icon: theme.icon,
            color: TemperatureColour(celsius: felt).hex,
            surface: .app(Self.appName),
            // An hour without a fresh reading and the clock drops the app on
            // its own — the only thing that survives this process ending
            // without a quit. An hour rather than something tighter because of
            // what the poll fits inside it: at `defaultInterval`'s 600 seconds
            // that is six refreshes, so five in a row have to fail before the
            // temperature leaves the loop, and a network hiccup or one slow
            // answer from a free public service cannot strip it off while this
            // app is alive and about to succeed. And an hour is where the
            // reading stops being weather anyway, so nothing is lost by waiting
            // that long to drop it.
            lifetime: 3_600,
            overlay: theme.overlay
        )
    }
```

- [ ] **Step 6: Split the Claude usage connector**

In `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift`:

(a) Replace `public func produce() async throws -> AwtrixDelivery { … }` (L57–62) with:

```swift
    /// The reporter's reading, or the reason there is none.
    public func read() async throws -> ClaudeUsageReading {
        // The gate first, so a poll outside working hours costs no request.
        guard showsNow() else { throw Failure.outOfFocus }
        guard let reading = try await reporter.read() else { throw Failure.noReading }
        return reading
    }

    public var awtrixFace: AwtrixFace<ClaudeUsageReading> {
        AwtrixFace { Self.output(for: $0) }
    }
```

(b) In the doc comment of `output(for:)`, replace `` /// Separated from `produce` so the drawing can be tested against a figure `` with `` /// Separated from `read()` so the drawing can be tested against a figure ``. The body of `output(for:)` does not change.

- [ ] **Step 7: Split the anecdote connector**

In `Sources/PixelClockKit/Connectors/AnecdoteConnector.swift`, replace `public func produce() async throws -> AwtrixDelivery { … }` (L270–289, doc comment included) with:

```swift
    /// Pops an anecdote that was prepared earlier, and retires it: reading one
    /// is playing it.
    ///
    /// This runs on a timer and is meant to be instant, so it does not top the
    /// queue up — `topUpIfNeeded` does, off this path. The one exception is an
    /// empty queue: with nothing to pop there is nothing else to show, so
    /// waiting for a batch buys the only anecdote there is.
    public func read() async throws -> PreparedAnecdote {
        var anecdote = await nextPlayable()
        if anecdote == nil {
            // One, not a batch. A cold first launch would otherwise pay the
            // model load plus a whole batch of synthesis before the clock shows
            // anything; the batch is `topUpIfNeeded`'s job, off this path.
            try await preparer.refill(target: 1)
            anecdote = await nextPlayable()
        }
        guard let anecdote else { throw Failure.nothingPrepared }
        await queue.retire(anecdote)
        return anecdote
    }

    public var awtrixFace: AwtrixFace<PreparedAnecdote> {
        AwtrixFace { self.output(for: $0) }
    }
```

`output(for:)` does not change. Its doc comment ("The two callers are `produce()` and the replay") stays true: `produce()` reaches it through the face.

- [ ] **Step 8: Update the session's comment**

In `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`, in the doc comment of `produceAndSend(_:)`, replace `` /// `AnecdoteConnector.produce()` pops an anecdote and retires it as played, `` with `` /// `AnecdoteConnector.read()` pops an anecdote and retires it as played, ``. The code does not change: it still calls `connector.produce()`.

- [ ] **Step 9: Give the test doubles a pass-through face and rename their method**

```swift
// Tests/PixelClockKitTests/PassThroughFace.swift
@testable import PixelClockKit

/// A test connector whose reading already is what the clock is to show draws
/// it unchanged.
///
/// Test-only on purpose. Every shipped connector reads a value and draws it,
/// and a default in the kit would let a new connector skip its face and still
/// compile.
extension Connector where Reading == AwtrixDelivery {
    var awtrixFace: AwtrixFace<AwtrixDelivery> { AwtrixFace { $0 } }
}
```

```swift
// Tests/PixelClockTilesAppTests/PassThroughFace.swift
import PixelClockKit

/// A test connector whose reading already is what the clock is to show draws
/// it unchanged. A second copy of the kit target's own, because test targets
/// do not import each other.
extension Connector where Reading == AwtrixDelivery {
    var awtrixFace: AwtrixFace<AwtrixDelivery> { AwtrixFace { $0 } }
}
```

```bash
perl -pi -e 's/func produce\(\) async throws -> AwtrixDelivery/func read() async throws -> AwtrixDelivery/' \
  Tests/PixelClockKitTests/AwtrixClockSessionTests.swift \
  Tests/PixelClockKitTests/ConnectorRegistryTests.swift \
  Tests/PixelClockKitTests/VoiceCasterTests.swift \
  Tests/PixelClockTilesAppTests/Doubles.swift
```

Run: `grep -rn "func produce()" Sources Tests`
Expected: exactly one line, in `Sources/PixelClockKit/Connectors/Connector.swift`: the extension.

`CountingConnector.produceCount` keeps its name. It now counts reads, and `deliverSendsTheBannerWithoutAskingTheConnectorToProduce` asserts it stays at zero, which still says what the test means: a replay never asks the connector for anything.

If the compiler cannot infer `Reading` for a double (`type '…' does not conform to protocol 'Connector'`), add `typealias Reading = AwtrixDelivery` to that double. Its test bodies do not change.

- [ ] **Step 10: Run the tests**

Run: `swift test --filter ConnectorFaceTests`
Expected: PASS, 5 tests.

Run: `swift test --filter 'WeatherConnectorTests|ClaudeUsageTests|AnecdoteConnectorTests|AwtrixClockSessionTests|ConnectorRegistryTests|VoiceCasterTests|AppShellTests'`
Expected: PASS. Counts as in Task 3 Step 7, plus `AppShellTests` unchanged.

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test`
Expected: PASS, `N0 + 14` tests.

- [ ] **Step 11: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: a connector reads, and its AWTRIX face draws what it read"
```

- [ ] **Step 12: Mutation checks — each moved guard still bites**

One at a time; revert each with `git restore <file>`.

| # | Site | Mutation | Filter | Must fail |
| --- | --- | --- | --- | --- |
| M4.1 | `ClaudeUsageConnector.read` | delete `guard showsNow() else { throw Failure.outOfFocus }` | `ClaudeUsageTests\|ConnectorFaceTests` | `nothingIsProducedWhileTheFocusIsNotOneOfItsOwn`, `theGateIsAskedBeforeTheServiceIs`, `aClosedGateStopsTheClaudeReadBeforeAnythingIsDrawn` |
| M4.2 | `ClaudeUsageConnector.read` | swap the two guards (reporter first) | `ClaudeUsageTests` | `theGateIsAskedBeforeTheServiceIs` |
| M4.3 | `AnecdoteConnector.read` | delete `await queue.retire(anecdote)` | `AnecdoteConnectorTests\|ConnectorFaceTests` | `playingAnAnecdoteMarksItSoItNeverRepeats`, `readingAnAnecdoteRetiresItAndItsFaceDrawsTheBanner` |
| M4.4 | `WeatherConnector.output(for:)` | `let felt = reading.apparentTemperature ?? reading.temperature` → `let felt = reading.temperature` | `WeatherConnectorTests` | `theColourIsChosenFromWhatItFeelsLikeRatherThanFromTheAirTemperature` |
| M4.5 | `Connector.produce()` | body → `_ = try await read(); return AwtrixDelivery(text: "")` | `ConnectorFaceTests\|WeatherConnectorTests` | `whatIsProducedIsWhatTheFaceDrawsOfWhatWasRead`, `theWeatherIsDrawnInTheClocksOwnLoopRatherThanOverIt` |
| M4.6 | `AnecdoteConnector.read` | delete the `if anecdote == nil { … }` refill | `AnecdoteConnectorTests` | `anEmptyQueueRefillsRatherThanShowingNothing`, `anEmptyQueuePreparesOneAnecdoteNotAWholeBatch` |
| M4.7 | `AnecdoteConnector.read` | `try await preparer.refill(target: 1)` → `try await preparer.refill(target: AnecdoteConnector.readyTarget)` | `AnecdoteConnectorTests` | `anEmptyQueuePreparesOneAnecdoteNotAWholeBatch` |
| M4.8 | `AnecdoteConnector.read` | first line only: `var anecdote = await nextPlayable()` → `var anecdote = await queue.next()` | `AnecdoteConnectorTests` | `anAnecdoteWhoseClipsAreGoneIsSkipped` |

After the last one, `git status --short` must print nothing.

---

### Task 5: Indicator custody belongs to the AWTRIX adapter

The record of what each lamp shows moves out of the app's `VPNLampDisplay` into the kit's `IndicatorCustody`, with its two rules: write only on a change, forget a write that failed. The session owns one, built on its own device. `VPNLampDisplay` keeps only what is about VPNs: which two corners, and that a quit darkens both. Lamp writes stay off the delivery chain, as they are today.

**Files:**
- Create: `Sources/PixelClockKit/Awtrix/IndicatorCustody.swift`
- Modify: `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift` (stored `indicators`, init)
- Modify: `Sources/PixelClockTilesApp/VPNLampDisplay.swift` (whole file)
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` — `live()` only
- Modify (arrange rename): `Tests/PixelClockTilesAppTests/VPNLampDisplayTests.swift` (6 sites), `Tests/PixelClockTilesAppTests/VPNIndicatorWiringTests.swift` (4 sites)
- Test: `Tests/PixelClockKitTests/IndicatorCustodyTests.swift` (new), `Tests/PixelClockTilesAppTests/IndicatorCustodyWiringTests.swift` (new)

**Interfaces:**
- Consumes: `enum IndicatorSlot: Int { topRight = 1, middleRight = 2, bottomRight = 3 }`, `enum IndicatorSignal { off, steady(String), blinking(String, everyMilliseconds: Int) }`, `AwtrixDevice.setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws`; the app's `struct VPNLamps { topRight, bottomRight; static let dark }`.
- Produces:
  - `public protocol IndicatorLighting: Sendable { func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws }` (moved from the app, now public) and `extension AwtrixDevice: IndicatorLighting {}` (moved)
  - `public actor IndicatorCustody` — `init(lamps: any IndicatorLighting)`, `func show(_ signal: IndicatorSignal, on slot: IndicatorSlot) async`
  - `AwtrixClockSession.indicators: IndicatorCustody` (`public nonisolated let`)
  - `struct VPNLampDisplay: Sendable` — `init(indicators: IndicatorCustody)`, `show(_ lamps: VPNLamps) async`, `clear() async`
- Production callers: `AppModel.live()` builds `VPNLampDisplay(indicators: session.indicators)`. `AppModel.refreshVPNIndicators()` and `AppModel.teardown()` keep calling `vpnLamps.show(_:)` and `vpnLamps?.clear()` unchanged.

**Proven template:** `VPNLampDisplay.write(_:_:)` — moved verbatim into `IndicatorCustody.show(_:on:)`.

- [ ] **Step 1: Write the composition-root test, and see it pass on today's wiring**

First, because the kit test in Step 2 stops the whole package's tests from compiling until Step 3. This one characterises existing behaviour: `live()` lights the corners through the same device every delivery uses. It passes before the refactor and must still pass after it.

```swift
// Tests/PixelClockTilesAppTests/IndicatorCustodyWiringTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The display and the custody are each proven on their own. This is the one
// line between them in `live()` — the kind of seam this project has already
// once found green on both banks with nothing crossing it.
@Test @MainActor func theCornersAreLitThroughTheClockTheAppTalksTo() async throws {
    let suite = "lamps-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubTransport(body: onlineStats)
    let subject = AppModel.live(
        defaults: defaults,
        transport: transport,
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("lamps-\(UUID().uuidString).json")
    )

    subject.refreshVPNIndicators()

    // Both corners on the first showing, whatever this machine's tunnels and
    // Focus say: nothing is known yet about what the lamps show.
    #expect(await waitUntil {
        Set(transport.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/api/indicator") })
            == ["/api/indicator1", "/api/indicator3"]
    })
}
```

Run: `swift test --filter IndicatorCustodyWiringTests`
Expected: PASS, 1 test. Today's `VPNLampDisplay(clock: device)` already does this.

- [ ] **Step 2: Write the kit's failing test**

```swift
// Tests/PixelClockKitTests/IndicatorCustodyTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The lamps are custody like the overlay and the apps in the loop: what
// matters is what LANDED on the clock. The app's VPN tests pin the same rules
// through the two corners; these pin them on the custody alone, which is what
// VPN tiles will stand on once the app's display is gone.

/// Records what reached the lamps, and can refuse like an unplugged clock.
private final class LampLog: IndicatorLighting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(slot: IndicatorSlot, signal: IndicatorSignal)] = []
    private var refused: Set<IndicatorSlot> = []

    var written: [(slot: IndicatorSlot, signal: IndicatorSignal)] { lock.withLock { recorded } }

    func refuse(_ slots: Set<IndicatorSlot>) { lock.withLock { refused = slots } }

    func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws {
        try lock.withLock {
            if refused.contains(slot) { throw AwtrixError.invalidHost("nowhere") }
            recorded.append((slot, signal))
        }
    }
}

@Test func aLampIsWrittenTheFirstTimeItIsShown() async {
    let log = LampLog()
    let custody = IndicatorCustody(lamps: log)

    await custody.show(.steady("#00F0FF"), on: .middleRight)

    #expect(log.written.count == 1)
    #expect(log.written.first?.slot == .middleRight)
    #expect(log.written.first?.signal == .steady("#00F0FF"))
}

@Test func showingWhatALampAlreadyShowsWritesNothing() async {
    let log = LampLog()
    let custody = IndicatorCustody(lamps: log)

    await custody.show(.steady("#00F0FF"), on: .middleRight)
    await custody.show(.steady("#00F0FF"), on: .middleRight)
    #expect(log.written.count == 1)

    await custody.show(.off, on: .middleRight)
    #expect(log.written.count == 2)
}

@Test func aWriteTheClockRefusedIsWrittenAgainNextTime() async {
    let log = LampLog()
    let custody = IndicatorCustody(lamps: log)
    log.refuse([.topRight])

    await custody.show(.steady("#A3FF12"), on: .topRight)
    #expect(log.written.isEmpty)

    log.refuse([])
    await custody.show(.steady("#A3FF12"), on: .topRight)
    #expect(log.written.count == 1)
}
```

Run: `swift test --filter IndicatorCustodyTests`
Expected: FAIL at compile time — `cannot find type 'IndicatorLighting' in scope` (it is still internal to the app) and `cannot find 'IndicatorCustody' in scope`.

- [ ] **Step 3: Create `IndicatorCustody.swift`**

```swift
// Sources/PixelClockKit/Awtrix/IndicatorCustody.swift
import Foundation

/// What the AWTRIX adapter needs of a clock's indicator lamps.
///
/// A protocol so the custody below can be posed to something that records
/// instead of to a clock on the desk. `AwtrixDevice` satisfies it as written.
public protocol IndicatorLighting: Sendable {
    func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws
}

extension AwtrixDevice: IndicatorLighting {}

/// What each of an AWTRIX clock's indicator lamps is showing, as far as this
/// app put it there.
///
/// The third kind of custody the AWTRIX adapter keeps, beside the borrowed
/// overlay and the apps in the loop. Lamps live on the clock and outlive the
/// app that lit them, so what matters is what LANDED. Remembering what was
/// asked for would rewrite a lamp that had not moved; remembering a failed
/// write would leave a lamp wrong until the thing it shows next changed, which
/// on a quiet afternoon is never.
///
/// An actor because the things that ask it to show something — a network path
/// change, a Focus switch, the minute poll, a launch — arrive from different
/// places and can overlap. Not on the delivery chain: a lamp is one POST and
/// must not wait behind a playing anecdote.
public actor IndicatorCustody {
    private let lamps: any IndicatorLighting

    /// What each lamp is showing, as far as a successful write can say. A slot
    /// missing from here has never been written or last failed — either way,
    /// this app does not know what that lamp looks like and writes it again.
    private var shown: [IndicatorSlot: IndicatorSignal] = [:]

    public init(lamps: any IndicatorLighting) {
        self.lamps = lamps
    }

    /// Shows `signal` on `slot`, unless that is what the slot already shows.
    public func show(_ signal: IndicatorSignal, on slot: IndicatorSlot) async {
        guard shown[slot] != signal else { return }
        do {
            try await lamps.setIndicator(slot, to: signal)
            shown[slot] = signal
        } catch {
            // Forgotten rather than recorded, so the next trigger writes it
            // again. An unreachable clock is the ordinary case here — the app
            // runs on a laptop and the clock is on a desk it is not always at.
            shown[slot] = nil
        }
    }
}
```

- [ ] **Step 4: The session owns the lamps' custody**

In `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`, after the `custody` property and its doc comment, add:

```swift
    /// The lamps' custody, over the same device every delivery goes through.
    /// Nonisolated because it is an actor of its own: the app hands it to the
    /// VPN display when it composes itself, without a hop through this one.
    public nonisolated let indicators: IndicatorCustody
```

In `init`, after `self.custody = DeviceCustody(device: device, overlays: borrowedOverlays)`, add:

```swift
        self.indicators = IndicatorCustody(lamps: device)
```

- [ ] **Step 5: Shrink `VPNLampDisplay` to the VPN corners**

Replace the whole of `Sources/PixelClockTilesApp/VPNLampDisplay.swift` with:

```swift
import Foundation
import PixelClockKit

/// Keeps the clock's two VPN corners in step with this machine.
///
/// The VPN half of the lamps: which two corners, and that a quit darkens both.
/// What each lamp shows, and writing only what moved, is the AWTRIX adapter's
/// `IndicatorCustody`; this asks it one corner at a time.
struct VPNLampDisplay: Sendable {
    private let indicators: IndicatorCustody

    init(indicators: IndicatorCustody) {
        self.indicators = indicators
    }

    func show(_ lamps: VPNLamps) async {
        await indicators.show(lamps.topRight, on: .topRight)
        await indicators.show(lamps.bottomRight, on: .bottomRight)
    }

    /// Puts both corners out, for a quit.
    ///
    /// Indicators live on the clock and outlive the app that set them — the
    /// firmware keeps them through a reconnect and through this process going
    /// away. Without this, quitting while the work tunnel was down would leave
    /// a red corner blinking on somebody's desk with nothing left running that
    /// could ever stop it.
    ///
    /// Both corners always, including one this launch never lit. The clock may
    /// still hold what an earlier run left there.
    func clear() async {
        await show(.dark)
    }
}
```

The `IndicatorLighting` protocol and the `extension AwtrixDevice: IndicatorLighting {}` that stood at the top of this file are gone. They now live in the kit, under the same names, and `RecordingLamps` in `Doubles.swift` conforms to the kit's protocol with no edit.

- [ ] **Step 6: Wire the display to the session's custody in `live()`**

In `Sources/PixelClockTilesApp/AppModel.swift`, inside `static func live(…)` only:

(a) Cut the `AwtrixClockSession(…)` expression from the `host:` argument of `return AppModel(`, including its `borrowedOverlays:` comment. Paste it directly above `return AppModel(` as a local:

```swift
        let session = AwtrixClockSession(
            device: device,
            registry: registry,
            store: store,
            audio: SequentialAudioPlayer(),
            iconInstaller: installer,
            // Durable, for the reason the uploaded-icon record is: what
            // this app did to the device is not knowable by looking at the
            // device afterwards. One exit without a teardown and an
            // in-memory record turns this app's own weather overlay into
            // the value it restores for ever.
            borrowedOverlays: UserDefaultsBorrowedOverlayStore(defaults: defaults)
        )

```

(b) Make the argument `host: session,`.

(c) Replace

```swift
            // The same device the connectors write through. Indicators do
            // not go into the loop, so they contend with nothing that does.
            vpnLamps: VPNLampDisplay(clock: device),
```

with

```swift
            // The session's own lamp custody, over the same device the
            // connectors write through. Indicators do not go into the loop, so
            // they contend with nothing that does.
            vpnLamps: VPNLampDisplay(indicators: session.indicators),
```

If Phase 1 has changed how `store` or `device` is built inside `live()`, keep its lines and use whatever local it names. Nothing else in `AppModel.swift` changes in this task.

- [ ] **Step 7: Rename the display's construction in the moved tests**

```bash
perl -pi -e 's/VPNLampDisplay\(clock: clock\)/VPNLampDisplay(indicators: IndicatorCustody(lamps: clock))/g' \
  Tests/PixelClockTilesAppTests/VPNLampDisplayTests.swift \
  Tests/PixelClockTilesAppTests/VPNIndicatorWiringTests.swift
```

Run: `grep -rn "VPNLampDisplay(clock" Sources Tests`
Expected: no output.

- [ ] **Step 8: Run the tests**

Run: `swift test --filter 'IndicatorCustodyTests|IndicatorCustodyWiringTests|VPNLampDisplayTests|VPNIndicatorWiringTests'`
Expected: PASS, 3 + 1 + 6 + 4 = 14 tests.

Run: `swift test --filter AppShellTests`
Expected: PASS. `whatAnEarlierLaunchBorrowedIsStillGivenBackInThisOne` guards the durable overlay store that the hoisted session must still be given.

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test`
Expected: PASS, `N0 + 18` tests.

- [ ] **Step 9: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: the AWTRIX session keeps custody of the indicator lamps"
```

- [ ] **Step 10: Mutation checks**

One at a time; revert each with `git restore <file>`.

| # | Site | Mutation | Filter | Must fail |
| --- | --- | --- | --- | --- |
| M5.1 | `IndicatorCustody.show` | delete `guard shown[slot] != signal else { return }` | `VPNLampDisplayTests\|IndicatorCustodyTests` | `showingTheSameThingAgainWritesNothing`, `aPartialDeliveryRemembersOnlyWhatLanded`, `showingWhatALampAlreadyShowsWritesNothing` |
| M5.2 | `IndicatorCustody.show` | in `catch`, `shown[slot] = nil` → `shown[slot] = signal` | `VPNLampDisplayTests\|IndicatorCustodyTests` | `aWriteThatFailedIsNotRememberedAsShown`, `aWriteTheClockRefusedIsWrittenAgainNextTime` |
| M5.3 | `VPNLampDisplay.clear` | body → empty | `VPNLampDisplayTests\|VPNIndicatorWiringTests` | `clearingPutsBothCornersOut`, `quittingPutsTheCornersOut` |
| M5.4 | `AppModel.live()` | `vpnLamps: VPNLampDisplay(indicators: session.indicators)` → `vpnLamps: nil` | `IndicatorCustodyWiringTests` | `theCornersAreLitThroughTheClockTheAppTalksTo` |
| M5.5 | `VPNLampDisplay.show` | `on: .bottomRight` → `on: .middleRight` | `VPNLampDisplayTests\|VPNIndicatorWiringTests\|IndicatorCustodyWiringTests` | `theFirstShowingWritesBothCorners`, `quittingPutsTheCornersOut`, `theCornersAreLitThroughTheClockTheAppTalksTo` |

After the last one, `git status --short` must print nothing.

---

### Task 6: Parity sweep and the handoff note

No production code. The task checks that the phase changed no behaviour and no assertion, then records what it leaves for later phases.

**Files:**
- Modify: `docs/HANDOFF.md` (append one section)

**Interfaces:**
- Consumes: `BASE` and `N0` from Task 0.
- Produces: nothing downstream reads.

- [ ] **Step 1: Build and count**

Run: `swift build 2>&1 | grep -c "warning:"`
Expected: `0`.

Run: `swift test --list-tests 2>/dev/null | wc -l`
Expected: `N0 + 18` — 6 chain, 3 delivery, 5 face, 3 custody, 1 wiring.

Run: `swift test`
Expected: PASS.

- [ ] **Step 2: No assertion changed except by the two renames**

```bash
git diff -M --diff-filter=MR "$BASE"..HEAD -- Tests \
  | grep -E '^[-+][^-+]' \
  | grep -E '#expect|#require|Issue\.record' \
  | perl -pe 's/^[-+]//; s/\bConnectorOutput\b/AwtrixDelivery/g; s/\bConnectorHost\b/AwtrixClockSession/g' \
  | sort | uniq -c | awk '$1 % 2 == 1'
```

Expected: no output. Every changed assertion line is a removed/added pair that differs only by `ConnectorOutput` → `AwtrixDelivery` or `ConnectorHost` → `AwtrixClockSession`. Any line printed is a rewritten assertion. Undo it.

Run: `git diff -M --diff-filter=D --name-only "$BASE"..HEAD -- Tests`
Expected: no output. No test file was deleted.

- [ ] **Step 3: The risky files were left alone**

Run: `git diff --stat "$BASE"..HEAD -- Sources/PixelClockTilesApp/MenuPanel.swift`
Expected: no output.

Run: `git diff "$BASE"..HEAD -- Sources/PixelClockTilesApp/AppModel.swift | grep '^@@'`
Expected: hunks only at `ConnectorRunning` / its conformance, `AnecdoteReplaying`, the three doc comments renamed in Task 2, and `live()`. A hunk inside any other method is a parity breach.

Run: `grep -rnw -e ConnectorOutput -e ConnectorHost -e 'VPNLampDisplay(clock' Sources Tests`
Expected: no output.

- [ ] **Step 4: Append the handoff note**

Append to the end of `docs/HANDOFF.md`:

```markdown
## PixelClockTiles Phase 2 — what it leaves for later phases

Phase 2 (`docs/superpowers/plans/2026-09-18-pixelclocktiles-phase2-ports-awtrix-parity.md`)
changed no behaviour. What it deliberately did not do, so the next phases do not
look for it:

- `ConnectorRunning` is still the app's name for a session; the kit type is
  `AwtrixClockSession`. Phase 4 renames the protocol when `AppModel` holds a
  session per clock.
- `DeliveryChain` is keyed by `String`. Phase 4 makes it generic over `TileKey`.
- Health — `DeviceMonitor`, `BatteryTrajectory`, relocation — is still in
  `AppModel`. It moves into the session in Phase 4.
- `AwtrixScene` is a struct with a `surface`, not the spec's enum. `.indicator`
  joins it in Phase 4 with the VPN tile's face, and indicator writes must stay
  off the delivery chain there too.
- `awtrixFace` is non-optional. Phase 3b adds `ulanziFace` as optional with a
  `nil` default in a protocol extension.
- No `Config` on `Connector`. It lands in Phase 4 with the weather tile's
  location, its first reader.
- `produce()` is the AWTRIX program. Phase 3b names the TC002 counterpart.
- The drawing tests stayed in their connector test files; Phase 3b moves them
  when TC002 face tests land beside them.
- `VPNLampDisplayTests` still pins lamp custody through the app's two corners.
  When Phase 4 deletes `VPNLampDisplay`, `IndicatorCustodyTests` carries the
  rules, and the generic "put out every lit lamp on quit" is Phase 4's to add.

Owed at the hardware (the desk clock is now a TC002, so this waits for a TC001
on the network): the weather app, the Claude app and an anecdote banner look as
they did before Phase 2; the VPN corners follow a Focus switch; a clean quit
removes the apps, restores the overlay and darkens both corners.
```

- [ ] **Step 5: Commit**

```bash
git add docs/HANDOFF.md
git commit -m "docs: what Phase 2 leaves for the phases after it"
```

---

## Appendix — existing symbols this plan relies on, verified at `39d7072`

Paths are shown with phase 0's names; line numbers are from before the rename (phase 0 did not change line counts except in import lines).

| Symbol | Signature | Where |
| --- | --- | --- |
| `ConnectorHost` | `public actor ConnectorHost` | `Sources/PixelClockKit/Scheduling/ConnectorHost.swift:53` |
| `ConnectorHost.init` | `init(device: AwtrixDevice, registry: ConnectorRegistry, store: any SettingsStore, audio: any AudioPlaying, iconInstaller: any IconInstalling, retryPolicy: RetryPolicy = RetryPolicy(), borrowedOverlays: any BorrowedOverlayStore = InMemoryBorrowedOverlayStore())` | `:78` |
| `restoreDeviceState` | `public func restoreDeviceState(borrowedBy connectorId: String?) async` | `:116` |
| `consecutiveFailures` | `public func consecutiveFailures(connectorId: String) -> Int` | `:121` |
| `nextDelay` | `public func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval` | `:137` |
| `record` | `private func record(_ result: RunResult, for connectorId: String)` | `:151` |
| `runOnce` | `public func runOnce(connectorId: String) async -> RunResult` | `:191` |
| `deliver` | `public func deliver(_ output: ConnectorOutput) async -> RunResult` | `:239` |
| `queued` | `private func queued(_ work: @escaping @Sendable () async -> RunResult) async -> RunResult` | `:253` |
| `maintain` | `public func maintain(connectorId: String) async -> MaintenanceResult` | `:282` |
| `produceAndSend` | `private func produceAndSend(_ connector: any Connector) async -> RunResult` | `:315` |
| `send` | `private func send(_ output: ConnectorOutput, from connectorId: String?) async -> RunResult` | `:326` |
| `classify` | `private func classify(_ error: any Error) -> RunResult` | `:425` |
| `RunResult`, `MaintenanceResult` | `public enum RunResult: Sendable, Equatable`, `public enum MaintenanceResult: Sendable, Equatable` | `:30`, `:43` |
| `AudioPlaying`, `IconInstalling`, `ConnectorMaintaining` | `func play(_ clips: [SpokenClip]) async`; `func ensureInstalled(_ ref: IconReference) async throws -> String`; `func maintain() async throws` | `:5`, `:9`, `:25` |
| `RetryPolicy` | `init(base: TimeInterval = 30, cap: TimeInterval = 1800)`; `func delay(afterConsecutiveFailures failures: Int) -> TimeInterval` | `Scheduling/RetryPolicy.swift:16`, `:28` |
| `SettingsStore` | `func storedSettings(for id: String) -> ConnectorSettings?`; `func save(_ settings: ConnectorSettings, for id: String)`; extension `func settings(for id: String) -> ConnectorSettings` | `Scheduling/ConnectorSettings.swift:61–85` |
| `ConnectorOutput` | `init(text: String, icon: IconReference? = nil, progress: ProgressBar? = nil, jingle: String? = nil, localAudio: [SpokenClip] = [], holdUntilAudioEnds: Bool = false, duration: Int? = nil, color: String? = nil, surface: DeliverySurface = .notification, lifetime: Int? = nil, overlay: DeviceOverlay? = nil)` | `Connectors/Connector.swift:78–136` |
| `IconReference`, `DeliverySurface`, `ProgressBar` | `enum IconReference { installed(String), catalogue(Int), bundled(String) }`; `enum DeliverySurface { notification, app(String) }`; `ProgressBar.init(percent:fill:track:)` | `Connector.swift:24`, `:52`, `:64` |
| `Connector` | `id`, `displayName`, `defaultInterval`, `narrator`, `isAudible`, `isAmbient`, `func produce() async throws -> ConnectorOutput` | `Connector.swift:139–196` |
| `WeatherConnector` | `init(source: OpenMeteoSource, location: @escaping @Sendable () -> Coordinates)`; `produce()`; `static func degrees(_ celsius: Double) -> String`; `static let appName = "weather"` | `Connectors/WeatherConnector.swift:75`, `:80`, `:129`, `:22` |
| `ClaudeUsageConnector` | `init(reporter: any ClaudeUsageReporting, showsNow: @escaping @Sendable () -> Bool = { true })`; `produce()`; `public static func output(for reading: ClaudeUsageReading) -> ConnectorOutput`; `enum Failure { noReading, outOfFocus }` | `Connectors/ClaudeUsageConnector.swift:49`, `:57`, `:81`, `:64` |
| `ClaudeUsageReporting` | `func read() async throws -> ClaudeUsageReading?` | `ClaudeUsageConnector.swift:10` |
| `ClaudeUsageReading` | `init(utilization: Int, resetsAt: Date?)` | `Claude/ClaudeUsageReading.swift:14` |
| `AnecdoteConnector` | `produce()`; `public func output(for anecdote: PreparedAnecdote) -> ConnectorOutput`; `private func nextPlayable() async -> PreparedAnecdote?`; `enum Failure { nothingPrepared }` | `Connectors/AnecdoteConnector.swift:276`, `:303`, `:331`, `:210` |
| `AnecdoteQueue` | `init(storeURL: URL, clipRoot: URL, retention: TimeInterval)`; `func retire(_:)`; `func hasPlayed(_ id: String) -> Bool` | `Anecdotes/AnecdoteQueue.swift:123`, `:226`, `:232` |
| `AnecdotePreparer`, `AnecdoteSource` | `init(source:speech:queue:caster:)`, `refill(target:) async throws -> Int`; `init(transport: Transport, feed: URL = AnecdoteSource.topFeed)` | `AnecdoteConnector.swift:87`, `:109`; `AnecdoteSource.swift:51` |
| `StubSpeechSynthesizer` | `public final class StubSpeechSynthesizer: SpeechSynthesizing` | `Speech/SpeechSynthesizing.swift:23` |
| `OpenMeteoSource` | `init(transport: any Transport, now: @escaping @Sendable () -> Date = Date.init)`; `func reading(at place: Coordinates) async throws -> WeatherReading` | `Weather/OpenMeteoSource.swift:118`, `:125` |
| `DeviceOverlay` | `public enum DeviceOverlay: String, Sendable, Equatable, CaseIterable` (`.clear`, `.rain`, …) | `Weather/WeatherTheme.swift:15` |
| `DeviceCustody` | `init(device:overlays:)`; `apply(_:for:)`; `show(_:named:for:)`; `restore(borrowedBy:)` | `Device/DeviceCustody.swift:50–150` |
| `IndicatorSlot`, `IndicatorSignal`, `setIndicator` | see Task 5 Interfaces | `Device/DeviceIndicator.swift:11`, `:29`, `:60` |
| `AwtrixError.invalidHost` | `case invalidHost(String)` | `Device/AwtrixError.swift:5` |
| `IndicatorLighting` (app) | `protocol IndicatorLighting: Sendable { func setIndicator(_:to:) async throws }`; `extension AwtrixDevice: IndicatorLighting {}` | `Sources/PixelClockTilesApp/VPNLampDisplay.swift:10`, `:14` |
| `VPNLampDisplay` | `actor VPNLampDisplay`; `init(clock: any IndicatorLighting)`; `func show(_ lamps: VPNLamps) async`; `func clear() async` | `VPNLampDisplay.swift:26–65` |
| `VPNLamps` | `struct VPNLamps { var topRight, bottomRight: IndicatorSignal; static let dark }` | `VPNIndicatorPolicy.swift:10` |
| `ConnectorRunning` | `maintain(connectorId:)`, `runOnce(connectorId:)`, `deliver(_ output: ConnectorOutput)`, `nextDelay(connectorId:interval:) async`, `restoreDeviceState(borrowedBy:)` | `AppModel.swift:16–36` |
| `AnecdoteReplaying` | `var id: String`; `func history() async -> [PlayedAnecdote]`; `func output(for anecdote: PreparedAnecdote) -> ConnectorOutput` | `AppModel.swift:51–55` |
| `AppModel.live` | `static func live(defaults: UserDefaults = .standard, transport: any Transport = URLSessionTransport(), anecdoteStore: URL = AppPaths.anecdoteStore) -> AppModel` | `AppModel.swift:535` |
| `AppModel.refreshVPNIndicators`, `teardown` | `func refreshVPNIndicators()`; `func teardown() async` (ends with `host.restoreDeviceState(borrowedBy: nil)` then `vpnLamps?.clear()`) | `AppModel.swift:1115`, `:1193` |
| Kit test support | `final class RecordingTransport` (`requests`, `body`); `func waitBudget(_ limit: TimeInterval?) -> TimeInterval` | `Tests/PixelClockKitTests/AwtrixDeviceSendTests.swift:17`; `Waiting.swift` |
| App test support | `StubTransport(body:)` with `requests`; `let onlineStats`; `@MainActor func waitUntil(_:limit:) async -> Bool`; `RecordingLamps: IndicatorLighting`; `SpyHost`, `QueueingHost`, `CancellingHost`, `RestockReportingHost`, `StubAnecdotes`, `modelOverRealHost`, `waitForFailures(of:on:toReach:limit:)` | `Tests/PixelClockTilesAppTests/Doubles.swift:407`, `:432`, `:312`, `:1206`, `:69`, `:601`, `:632`, `:729`, `:541`, `:812`, `:711` |
