import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// MARK: - What an unconfigured connector is set to

// The store answers `ConnectorSettings()` — thirty minutes — for a connector
// nobody has configured, and cannot say whether those thirty minutes were
// chosen or invented. A connector that declares five is the case that tells the
// two apart, which is why the stub's default is not thirty.
@Test @MainActor func aConnectorNobodyConfiguredIsScheduledAtItsOwnDefaultInterval() {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let subject = testModel(connectors: [connector])

    #expect(subject.settings(for: connector).interval == 5 * 60)
    #expect(subject.settings(for: connector).intervalPosition == 0)
}

@Test @MainActor func aConnectorNobodyConfiguredIsStillOn() {
    let connector = StubConnector(defaultInterval: 5 * 60)

    #expect(testModel(connectors: [connector]).settings(for: connector).isEnabled)
}

// A default interval the scale cannot represent exactly lands on the nearest
// position it can, because the slider has nowhere else to sit.
@Test @MainActor func aDefaultIntervalOffTheScaleLandsOnTheNearestPosition() {
    let connector = StubConnector(defaultInterval: 7 * 60)

    #expect(testModel(connectors: [connector]).settings(for: connector).interval == 5 * 60)
}

@Test @MainActor func whatTheUserChoseWinsOverTheConnectorsDefault() {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 3), for: connector.id)

    let subject = testModel(connectors: [connector], store: store)

    #expect(subject.settings(for: connector).isEnabled == false)
    #expect(subject.settings(for: connector).intervalPosition == 3)
}

// Touching the toggle must not quietly rewrite the interval. Saving from the
// store's own fallback rather than from the resolved settings would write
// thirty minutes over a connector that declared five, and the default it
// declares would never be seen again.
@Test @MainActor func togglingAConnectorNobodyConfiguredKeepsItsOwnDefaultInterval() {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let store = InMemorySettingsStore()
    let subject = testModel(connectors: [connector], store: store)

    subject.setEnabled(false, for: connector)

    #expect(store.storedSettings(for: connector.id)?.intervalPosition == 0)
    #expect(store.storedSettings(for: connector.id)?.isEnabled == false)
    #expect(subject.settings(for: connector).intervalPosition == 0)
}

@Test @MainActor func movingTheSliderIsSavedAndReadBack() {
    let connector = StubConnector()
    let store = InMemorySettingsStore()
    let subject = testModel(connectors: [connector], store: store)

    subject.setIntervalPosition(7, for: connector)

    #expect(store.storedSettings(for: connector.id)?.intervalPosition == 7)
    #expect(subject.settings(for: connector).intervalPosition == 7)
}

// MARK: - The schedule

@Test @MainActor func aScheduledConnectorDoesNotFireOnTheSpot() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.durations.contains(5 * 60) }

    // Launching the app reschedules every connector. Firing on the spot would
    // put an anecdote on the clock at every launch, which nobody asked for.
    #expect(host.calls.isEmpty)
    await subject.teardown()
}

@Test @MainActor func aScheduleSleepsTheConnectorsOwnInterval() async {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let schedule = Metronome()
    let subject = testModel(connectors: [connector], sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.durations.contains(5 * 60) }

    #expect(schedule.durations.contains(5 * 60))
    await subject.teardown()
}

// The interval is what the host is ASKED about, not what the schedule then
// waits. A connector that is failing is retried on the host's backoff, and a
// loop that slept its own `interval` variable would be right in every test
// where the two agree and never back anything off in the one place it matters.
@Test @MainActor func theScheduleWaitsAsLongAsTheHostSays() async {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let host = SpyHost(delay: 42)
    let schedule = Metronome()
    let subject = testModel(connectors: [connector], host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.durations.contains(42) }

    #expect(schedule.durations.contains(42))
    // The other half: the interval is not ALSO slept. Only the monitor's own
    // twenty seconds keeps it company.
    #expect(schedule.durations.contains(5 * 60) == false)
    await subject.teardown()
}

// Asked before every wait, not once when the schedule is built. A loop that
// read it at the top would answer with the count as it stood before the first
// run and never see a failure at all.
@Test @MainActor func theScheduleAsksHowLongToWaitBeforeEveryRun() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    // The schedule's own clock, not an aggregate over both loops. `tick()`
    // releases whatever is parked on the clock it is called on, so counting
    // sleepers across the poll and the schedule together would let the poll
    // answer for the schedule and tick a connector that has not yet reached
    // its sleep.
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    await waitUntil { host.delayQueries == 2 }

    #expect(host.delayQueries == 2)
    await subject.teardown()
}

// The whole reason the background pass has its own entry point. `produce()`
// only awaits a refill when the queue is empty, so a tick that never maintains
// turns every firing into a 70-second model load on the play path.
@Test @MainActor func everyTickMaintainsBeforeItRuns() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.parked > 0 }
    schedule.tick()
    await waitUntil { host.calls.count >= 2 }

    #expect(host.calls == ["maintain:stub", "run:stub"])
    await subject.teardown()
}

@Test @MainActor func theScheduleKeepsFiring() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    for _ in 0..<2 {
        // Parked, then released, then parked again — all on the schedule's
        // clock, so each beat is this connector's and no other loop can spend
        // one for it.
        #expect(await waitUntil { schedule.parked == 1 })
        schedule.tick()
    }
    await waitUntil { host.calls.count >= 4 }

    #expect(host.calls == ["maintain:stub", "run:stub", "maintain:stub", "run:stub"])
    await subject.teardown()
}

@Test @MainActor func aDisabledConnectorIsNeverScheduled() async {
    let off = StubConnector(id: "off", defaultInterval: 5 * 60)
    let on = StubConnector(id: "on", defaultInterval: 10 * 60)
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: off.id)
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [off, on], host: host, store: store, sleep: schedule.sleep
    )

    subject.start()
    // A second connector that IS on, so the negative claim has a witness. On
    // its own, "the schedule clock was never asked" is satisfied just as well
    // by a model that never got started at all — which is how this test used to
    // pass on a run where nothing had reached a sleep yet.
    #expect(await waitUntil { schedule.durations.contains(10 * 60) })

    #expect(schedule.durations == [10 * 60])
    #expect(host.calls.isEmpty)
}

@Test @MainActor func switchingAConnectorOffStopsItsSchedule() async {
    let connector = StubConnector()
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(connectors: [connector], host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.parked > 0 }
    subject.setEnabled(false, for: connector)
    // The schedule is gone, so releasing whatever was parked releases a sleep
    // nobody is looping on any more.
    schedule.tick()
    #expect(await waitUntil({ host.calls.isEmpty == false }, limit: 0.05) == false)

    #expect(host.calls.isEmpty)
}

// Changing the interval has to replace the schedule, not add to it. The
// interval is read once when the loop starts, so a schedule left running keeps
// firing on the old one — and both then fire, for ever.
@Test @MainActor func changingTheIntervalReplacesTheScheduleRatherThanAddingOne() async {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(connectors: [connector], host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.parked > 0 }
    subject.setIntervalPosition(1, for: connector)
    await waitUntil { schedule.durations.contains(10 * 60) }
    schedule.tick()
    await waitUntil { host.calls.count >= 2 }

    // One tick, not two: the schedule that was sleeping five minutes is gone.
    #expect(await waitUntil({ host.calls.count > 2 }, limit: 0.05) == false)
    #expect(host.calls == ["maintain:stub", "run:stub"])
    #expect(schedule.durations.contains(10 * 60))
    await subject.teardown()
}

// A cancelled sleep is the quit path. Swallowing the throw and carrying on
// would start one more delivery while the app is being torn down — a banner put
// on the clock by the very act of quitting.
@Test @MainActor func aCancelledScheduleDoesNotStartOneLastRun() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.parked > 0 }
    await subject.teardown()

    #expect(host.calls.isEmpty)
}

// MARK: - Quit

// Cancelling a delivery does not release its caller: the held banner's dismiss
// is sent on a task cancellation cannot break. Returning from teardown before
// the tick does lets the process die mid-release, and the clock keeps the
// banner until somebody presses the middle button.
@Test @MainActor func teardownWaitsForADeliveryThatIsAlreadyRunning() async {
    let gate = Gate()
    let host = SpyHost(parkInRun: gate)
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.parked > 0 }
    schedule.tick()
    await waitUntil { gate.enteredCount == 1 }

    let finished = Signal()
    Task { await subject.teardown(); finished.send() }
    #expect(await waitUntil({ finished.isSent }, limit: 0.05) == false)

    gate.open()
    #expect(await waitUntil { finished.isSent })
}

@Test @MainActor func aRunReachesTheHostAndItsOutcomeIsShown() async {
    let host = SpyHost()
    let subject = testModel(host: host)

    subject.runNow("stub")
    await waitUntil { subject.lastResults["stub"] == "delivered" }

    #expect(host.calls == ["run:stub"])
    #expect(subject.lastResults["stub"] == "delivered")
}

// Measured on this machine: a run against an empty queue takes 37.6 s, because
// `produce()` refills inline when it has nothing to hand out and the first
// refill of a process pays a 30-second model load. For all of that time the
// panel showed nothing at all, and a button that shows nothing for half a
// minute has, as far as anyone pressing it can tell, done nothing.
//
// So the run says it is running before it says how it went.
@Test @MainActor func aRunSaysItIsRunningBeforeItSaysHowItWent() async {
    let gate = Gate()
    let subject = testModel(host: SpyHost(parkInRun: gate))

    subject.runNow("stub")
    await waitUntil { gate.enteredCount == 1 }

    #expect(subject.lastResults["stub"] == "running…")

    gate.open()
    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
}

// A scheduled tick is silent for exactly as long, and the panel would show the
// previous run's outcome the whole time — a "delivered" that is half an hour
// stale while a delivery is in progress.
@Test @MainActor func aScheduledRunSaysItIsRunningToo() async {
    let gate = Gate()
    let schedule = Metronome()
    let subject = testModel(host: SpyHost(parkInRun: gate), sleep: schedule.sleep)

    subject.start()
    await waitUntil { schedule.parked > 0 }
    schedule.tick()
    await waitUntil { gate.enteredCount == 1 }

    #expect(subject.lastResults["stub"] == "running…")
    gate.open()
    await subject.teardown()
}

// The run the user asked for puts the same held banner on the clock as a
// scheduled one. Its task is owned by the button's action closure unless the
// model takes it, and a quit cannot wait for something it does not hold — so
// quitting mid-run would kill the process during the release and leave the
// banner up, which is the whole failure the budget exists for.
@Test @MainActor func teardownWaitsForARunTheUserAskedFor() async {
    let gate = Gate()
    let subject = testModel(host: SpyHost(parkInRun: gate))

    subject.runNow("stub")
    await waitUntil { gate.enteredCount == 1 }

    let finished = Signal()
    Task { await subject.teardown(); finished.send() }
    #expect(await waitUntil({ finished.isSent }, limit: 0.05) == false)

    gate.open()
    #expect(await waitUntil { finished.isSent })
}

// MARK: - Reachability

@Test @MainActor func theGlyphsOnlineFlagFollowsTheMonitor() async {
    let poll = Metronome()
    let subject = testModel(transport: StubTransport(body: onlineStats), pollSleep: poll.sleep)

    #expect(subject.isDeviceOnline == false)
    subject.start()

    #expect(await waitUntil({ subject.isDeviceOnline }))
    await subject.teardown()
}

@Test @MainActor func aDeviceThatCannotBeReachedLeavesTheGlyphUnlit() async {
    let poll = Metronome()
    let subject = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)), pollSleep: poll.sleep
    )

    subject.start()
    // Waited for the answer, not for the absence of one. `state` starts
    // `.unknown`, which is also not online, so waiting on `isOnline == false`
    // would return before the poll had run at all — and then the mirror could
    // be assigning anything and this would still pass.
    #expect(await waitUntil {
        if case .offline = subject.monitor.state { return true }
        return false
    })

    #expect(subject.isDeviceOnline == false)
    await subject.teardown()
}

// MARK: - Icons

@Test @MainActor func removingIconsTakesOffExactlyWhatThisAppUploaded() async {
    let transport = StubTransport()
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = testModel(transport: transport, uploads: uploads)

    subject.removeInstalledIcons()
    #expect(await waitUntil { subject.iconStatus == "removed 9039" })

    let deletions = transport.requests.filter { $0.httpMethod == "DELETE" }
    #expect(deletions.count == 1)
    let body = String(decoding: deletions.first?.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("/ICONS/9039.gif"))
    #expect(subject.iconStatus == "removed 9039")
}

@Test @MainActor func removingNothingSaysSoRatherThanClaimingSuccess() async {
    let transport = StubTransport()
    let subject = testModel(transport: transport)

    subject.removeInstalledIcons()
    #expect(await waitUntil { subject.iconStatus == "nothing this app uploaded" })

    #expect(transport.requests.isEmpty)
}

@Test @MainActor func aRemovalTheDeviceRefusesIsReportedRatherThanSwallowed() async {
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = testModel(
        transport: StubTransport(status: 500, body: Data("boom".utf8)), uploads: uploads
    )

    subject.removeInstalledIcons()
    #expect(await waitUntil { subject.iconStatus == "could not remove 9039" })

    // Still recorded, so the next attempt can take it off.
    #expect(uploads.uploadedIcons() == ["9039"])
}

/// A one-shot flag a test can wait on.
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false

    var isSent: Bool { lock.withLock { sent } }
    func send() { lock.withLock { sent = true } }
}

// The same silence the run button had, on the button one divider away:
// `removeUploaded` sends one DELETE per recorded icon and each costs the
// transport's full timeout against a device that has stopped answering.
@Test @MainActor func removingIconsSaysSoBeforeItStarts() async {
    let gate = Gate()
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = testModel(transport: GatedTransport(gate: gate), uploads: uploads)

    subject.removeInstalledIcons()
    await waitUntil { gate.enteredCount == 1 }

    #expect(subject.iconStatus == "removing…")
    gate.open()
    #expect(await waitUntil { subject.iconStatus == "removed 9039" })
}

// The removal task belongs to the model for the same reason the run's does:
// teardown can only wait for a task it holds. Lower stakes than a held banner —
// a delete cut short leaves the record intact — but it is the identical shape,
// and it was left in the view by the same commit that fixed it for runs.
@Test @MainActor func teardownWaitsForAnIconRemoval() async {
    let gate = Gate()
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = testModel(transport: GatedTransport(gate: gate), uploads: uploads)

    subject.removeInstalledIcons()
    await waitUntil { gate.enteredCount == 1 }

    let finished = Signal()
    Task { await subject.teardown(); finished.send() }
    #expect(await waitUntil({ finished.isSent }, limit: 0.05) == false)

    gate.open()
    #expect(await waitUntil { finished.isSent })
}

@Test @MainActor func asecondRemovalPressWhileOneIsRunningIsIgnored() async {
    let gate = Gate()
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = testModel(transport: GatedTransport(gate: gate), uploads: uploads)

    subject.removeInstalledIcons()
    await waitUntil { gate.enteredCount == 1 }
    subject.removeInstalledIcons()

    // One pass over the record, not two racing over the same names.
    #expect(await waitUntil({ gate.enteredCount > 1 }, limit: 0.05) == false)
    gate.open()
    #expect(await waitUntil { subject.iconStatus == "removed 9039" })
}

// MARK: - What the panel says while work is happening

// The scheduled tick's expensive half is `maintain`, not `runOnce`: a refill
// loads the model and synthesizes a batch, and after it the run finds a full
// queue and is quick. A marker written between the two lands exactly where the
// wait is already over, and the panel shows the previous run's outcome for the
// whole minute — which is the defect, not the fix for it.
@Test @MainActor func theScheduledTickSaysItIsRunningBeforeTheRefillRatherThanAfterIt() async {
    let refill = Gate()
    let schedule = Metronome()
    let subject = testModel(
        host: SpyHost(parkInMaintain: refill), sleep: schedule.sleep
    )

    // A previous run's outcome on the panel, which is what the user is looking
    // at when the next tick starts.
    subject.runNow("stub")
    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    await waitUntil { refill.enteredCount == 1 }

    #expect(subject.lastResults["stub"] == "running…")
    refill.open()
    await subject.teardown()
}

// What a person does after 37 seconds of silence is press it again. Run 1
// finishing then writes `delivered` while run 2 is still going, and the panel
// is back to claiming a finished delivery during a running one — the same lie,
// provoked by the very behaviour the silence induces.
@Test @MainActor func aFinishedRunDoesNotSpeakWhileALaterOneIsStillGoing() async {
    let host = QueueingHost()
    let subject = testModel(host: host)

    subject.runNow("stub")
    subject.runNow("stub")
    #expect(await waitUntil { host.started == 2 })

    host.finish(0)
    // Run 1 is done and run 2 is not. Nothing may claim a delivery yet.
    #expect(await waitUntil({ subject.lastResults["stub"] != "running…" }, limit: 0.05) == false)
    #expect(subject.lastResults["stub"] == "running…")

    host.finish(1)
    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
}

// The count has to come back down, or the panel is stuck on `running…` for the
// rest of the session — the opposite failure, and the one a naive "only the
// last one speaks" flag would introduce.
@Test @MainActor func twoRunsOneAfterAnotherEachReportWhenTheyAreTheOnlyOneLeft() async {
    let host = QueueingHost()
    let subject = testModel(host: host)

    subject.runNow("stub")
    #expect(await waitUntil { host.started == 1 })
    host.finish(0)
    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })

    subject.runNow("stub")
    #expect(await waitUntil { host.started == 2 })
    #expect(subject.lastResults["stub"] == "running…")
    host.finish(1)
    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
}

// The `.cancelled` case of `record`, which nothing exercised. A quit during a
// run must leave the panel saying what happened rather than stuck at `running…`.
@Test @MainActor func aRunCancelledByQuittingSaysSoRatherThanStayingAtRunning() async {
    let host = CancellingHost()
    let subject = testModel(host: host)

    subject.runNow("stub")
    #expect(await waitUntil { host.entered == 1 })
    await subject.teardown()

    #expect(subject.lastResults["stub"] == "cancelled")
}

// Teardown's own docstring is about waiting for deliveries, and the poll is the
// other loop it owns. Left running it would keep asking an unreachable device
// for its battery while the app is trying to die.
@Test @MainActor func teardownStopsTheReachabilityPollToo() async {
    let poll = Metronome()
    let subject = testModel(transport: StubTransport(body: onlineStats), pollSleep: poll.sleep)

    subject.start()
    #expect(await waitUntil { poll.parked == 1 })

    await subject.teardown()

    // Released after teardown: a loop that is still there re-parks, a cancelled
    // one does not.
    poll.tick()
    #expect(await waitUntil({ poll.parked == 1 }, limit: 0.05) == false)
}
