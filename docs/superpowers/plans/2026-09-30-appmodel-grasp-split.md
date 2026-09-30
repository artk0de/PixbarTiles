# AppModel by GRASP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dinopowers:executing-plans to implement this plan task-by-task; TDD through dinopowers:test-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 3 577-line `AppModel` into information experts behind an unchanged facade, so tiles, schedules and clocks each have one owner, and the tile-kind work (plan 3) edits small experts instead of the hub.

**Architecture:** Each cluster of `AppModel` becomes a `@MainActor final class` that owns its state and its behaviour.
- **The facade.** `AppModel` keeps every public member, its `init` signature and `live(...)`, and forwards to the experts. It relays their `objectWillChange`, so views and the four facade models see no change.
- **Cycles.** Where experts call each other, they depend on narrow protocols, never on `AppModel`.
- **Owned tasks.** Every task an expert starts goes through one shared `TaskBag`, so `teardown` still awaits everything in flight.

**Tech Stack:** Swift 6.2, SwiftUI/Combine, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-30-tile-kinds-and-animation-engine-design.md` §3.

## Global Constraints

- **Tests.** Business-logic tests are not rewritten. `testModel(...)` and `modelOverRealHost(...)` may change inside, never their call sites.
- **Public surface.**
  - Every member the map lists as used by views, facades or tests stays on `AppModel` with the same signature.
  - Nested types stay reachable as `AppModel.X`: `ClockReachability`, `PushState`, `ClockSaveOutcome`, `ZaiKeyOutcome`, `TokenOutcome`, `TileSaveOutcome`, `RelocatingHost`, `Sleeping`, and the static keys.
  - This holds as nested types or `typealias`es.
- **Publishers.** The only `$` publishers read outside the model are `$isDeviceOnline` and `$clocksSectionVisible`, both from `ClockBrowsingPolicy`. A source site may move to the expert's publisher.
- **Behaviour is unchanged.**
  - Every task ends with `swift test --no-parallel --filter PixbarTilesAppTests` green: 879 tests at the start.
  - The kit suite is untouched.
- **Comments move with the code**, verbatim: they carry the reasons.
- **Lexicon.** Before each commit, new names are checked with `get_naming_lexicon`. MISFIT, COLLISION and NO_CONVENTION verdicts are resolved first.
- **Commits.** One green commit per task, after the change summary has been shown and approved. Never push.
- **Index.** After each commit, run `tea-rags index-codebase --project pixelclocktiles-worktree-night-light-tile`.

## Pattern every extraction follows

```swift
@MainActor
final class Expert: ObservableObject {
    @Published private(set) var state: …          // moved from AppModel, same name
    init(<collaborators it reads>, tasks: TaskBag) { … }
    func behaviour(…) { … }                        // moved verbatim, `self.` now the expert
}

// AppModel
private let expert: Expert
var state: … { expert.state }                     // the public name, forwarded
func behaviour(…) { expert.behaviour(…) }         // likewise
// in init, once per expert:
relay = expert.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
```

- **Moving `@Published` state.** When a `@Published` property moves, the facade's computed forward keeps every reader compiling. The relay keeps every observer redrawing.
- **Setters.** A `didSet` that wrote defaults moves with the property.
- **Settable properties** read by tests (e.g. `typedHost`) forward both `get` and `set`.

## Tasks

Order matters: each expert may depend only on the ones before it.

### Task 1: `TaskBag`, the one registry of owned tasks

**Files:**
- Create: `Sources/PixbarTilesApp/TaskBag.swift`
- Create: `Tests/PixbarTilesAppTests/TaskBagTests.swift`
- Modify: `AppModel.swift`: `manualRuns`/`nextRunKey`, `replays`/`nextReplayKey`, `restores`/`nextRestoreKey`, `vpnPushes`, `historyLoad`, `iconRemoval`, `launchRestock`, `microphoneWatch`, `panelRefresh`, `monitorLoop`, `teardown`.

**Interfaces (produced):**

```swift
@MainActor final class TaskBag {
    /// Starts work that removes itself when done.
    func run(_ work: @escaping @MainActor () async -> Void)
    /// Starts work under a name, cancelling the one already under it.
    func replace(_ name: String, _ work: @escaping @MainActor () async -> Void)
    /// Starts work under a name unless one is still running; false when it is.
    @discardableResult func startIfIdle(_ name: String, _ work: @escaping @MainActor () async -> Void) -> Bool
    func isRunning(_ name: String) -> Bool
    func cancel(_ name: String)
    /// Cancels everything and waits for all of it — plus any extra tasks handed in (the schedule's timers).
    func cancelAndWait(also extra: [Task<Void, Never>] = []) async
}
```

**Tests:**
- anonymous work removes itself;
- `replace` cancels the previous task under the name;
- `startIfIdle` refuses while one runs and accepts after it ends;
- `cancelAndWait` awaits an uncancellable tail (a `withTaskCancellationHandler`-free body that finishes after a yield) before returning;
- extra tasks are cancelled and awaited too.

`AppModel` keeps `timers: [TileKey: Task]`, which is semantic, until Task 5; `teardown` passes `Array(timers.values)` as `extra`.

### Task 2: `ClockSessions`

- **Moves:** `sessions`, `makeSession`, `makeClockRegistry`, `clockRegistries`, `registry` (read-only reference), `session(for:)`, `connector(for:)`, `ulanziSession(for:)`, and the session half of `reloadClocks` (build / shut down sessions for added / removed clocks).
- **Produces:** `ClockSessions.session(for clockId:)`, `.connector(for key:)`, `.ulanzi(for clockId:)`, `.all`, `.reconcile(with clocks:)`.
- **Tests:** a removed clock's session is shut down, and a new clock gets one from `makeSession`; the registry cache is per clock.

### Task 3: `ClockHealthMonitor`

- **Moves:** `healths`, `ulanziHealths`, `device`, `isDeviceOnline` (`@Published`), `healthRevision`, `monitorLoop`, `panelRefresh`, `lastPanelRefresh`, `pollSleep`, `alerts`, `monitor`, `reachability(of:)`, `pushState(of:)`, `statusLine`, `batteryLine`, `battery(of:)`, `startMonitoring`, `ulanziHealth(for:device:)`, `Crossing`, `poll()`, `answerForSelectedClock`, `clockIsUnreachable`, `recheckClocks`, `forgetFailuresOfUnreachableClocks`.
- **Produces:** `protocol ReachabilityReading { func clockIsUnreachable(_ id: UUID) -> Bool; func recheckClocks() }`.
- **What stays in the facade.** `poll()`'s orchestration (labels, launch debt, reconcile, lamps) stays as a closure the monitor calls after each poll, `onPolled`. That closure is the only way back into the other experts.
- **`ClockBrowsingPolicy.watch`** subscribes to `monitor.$isDeviceOnline`.

### Task 4: `TileBook`

- **Moves:** tile CRUD, policy, catalogue and availability: `policy(of:)`, `storedTile`, `runningTile`, `settings(for:)`, `resolved`, `setEnabled`, `setPaused`, `setIntervalPosition`, `availability`, `addTile`, `restoreKey`, `saveTile`, `removeTile`, `storedPolicy`, `candidate`, `tileCandidates`, `tileRecords`, `lastResult(of:)`, `lastFailure(of:)`, `hold(of:)`, `moveTile`, `tileName`, `tileTitle`, `detailValue`, `newTileIntervalSeconds`, `setNewTileInterval`, `tileOrderRevision`.
- **Adds:** `rekey(tile:to:config:)`, replacing the shared body of `changeGitHubRepo` and `changeLampVPN`.
- **Depends on:** `TileScheduling` (`reschedule`, `reconcileTiles`) and `TileRunning` (`retract`, `pushDisplaySettings`, `giveBackDeviceState`). Both are implemented by the facade until Tasks 5–6 hand them to their experts.
- **Tests:** `rekey` moves the policy and config to the new key, and retires the old key's timer and page.

### Task 5: `TileRunner`

- **Moves:** `tileLastResults`, `tileLastFailures`, `tileLastMaintenanceFailure` (`@Published`), `outstanding`, `heldRuns`, `displayPushes`/`Owed`, `pushDisplaySettings`, `giveBackDeviceState`, `retract`, `runNow`, `tick`, `runAndReport`, `restock`, `markUnderWay`, `reportOutcome`, `note`, `record`, `noteDelivery`, `words(for:)`.
- **Conforms to:** `TileRunning`.

### Task 6: `TileScheduler`

- **Moves:** `timers`, `scheduledDue`, `tileNextRun`, `verdicts`, `launchDeliveriesOwed`, `launchRestock`, `start`'s schedule half, `noteLaunchDeliveries`, `deliverWhatTheLaunchOwes`, `restockAtLaunch`, `reconcileTiles`, `reschedule`, `scheduleHold`, `inItsOwnQuietHours`, `isAudible`, `busyMicrophone`, `currentFocus`, `currentHour`, and the labels (`noteNextRun`, `whatIsLeftOf`, `publishNextRun`, `refreshScheduleLabels`).
- **Conforms to:** `TileScheduling`.

### Task 7: `LampController`

- **Moves:** `vpn`, `vpnPushes`, `networkWatcher`, `focusWatcher`, `freeLampVPN`, `startingLamp`, `changeLampVPN` (via `TileBook.rekey`), `lampTiles`, `startWatchingTheWorld`, `refreshLamps`, the lamps half of `teardown`.
- **Also:** drop the stored but never read `vpnPresence`, keeping the init parameter.

### Task 8: `PageFollower`

- **Moves:** `detailTileKey`, `openDetail`, `closeDetail`, `PageFollow`, `pageFollow`, `pageWork`, `queuePageWork`, `pageSwitchesSettled`, `ownsPage`, `pageShowing`, `tileOnScreen`, `pageBelief`, `ulanziWatcher(for:)`, `forgetPageBelief`, `refreshTileOnScreen`, `showOnClock`, `readTileOnScreen`, `tile(showing:on:via:)`, `followPage`, `returnPage`, `showed`.
- **Adds:** `idle(_ key:)`, the TC002 `markIdle` path the night light needs.

### Task 9: `AnecdoteHistory`, `MicrophoneWatch`, `IconMaintenance`

Three small experts, one commit each: the C12, C13 and C14 members of the responsibility map.

### Task 10: Secrets and GitHub onto `TileBook` actions

- **Moves:** `saveZaiKey`, `hasZaiKey`, `saveGitHubToken`, `hasGitHubToken`, `addGitHubTile`, `changeGitHubRepo`, `gitHubDiagnosis` and the two outcome properties go to a `TileSecrets` expert.
- **In plan 3** these move again, onto the z.ai and GitHub wirings.

### Task 11: `ClockDirectory` and `AppComposition`

- **`ClockDirectory`** takes the clock list, selection, add / rename / remove / move and the address / location fields.
- **`AppModel.live` and `anecdoteWiring`** move to `AppComposition.swift`, as `extension AppModel`, which is Creator: it builds the experts.
- **Result:** `AppModel.swift` ends as the facade, and each expert has its own file.

## Self-review

- **Spec coverage.** §3's table maps one to one onto Tasks 2–11, `TaskBag` is Task 1, and the `App.swift` split is done (commit fb857eb).
- **Deliberately not code-complete.** Tasks 2–11 are moves of existing code. The code is `AppModel.swift`'s own, at the line ranges in the responsibility map, and each task names every member it moves. Each task's new tests are written first, per the TDD sub-skill.
