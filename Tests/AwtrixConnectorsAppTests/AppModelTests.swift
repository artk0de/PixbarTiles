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
    //
    // No RUN, rather than nothing at all: the launch does top the queue up, and
    // that is the point of it — the restock is what stops the first delivery of
    // the session from waiting on a model load.
    #expect(host.calls.contains("run:stub") == false)
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
    // The other half: the interval is not ALSO slept. Nothing else is on this clock:
    // the reachability poll sleeps on its own.
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
    // The launch top-up first, waited out so what follows is the tick's own.
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    await waitUntil { host.calls.count >= 3 }

    // The tick's own two, in order. What comes after the run is the post-run
    // restock, which `aScheduledRunRestocksAfterItFinishesAsWellAsBefore` owns.
    #expect(Array(host.calls.dropFirst().prefix(2)) == ["maintain:stub", "run:stub"])
    await subject.teardown()
}

@Test @MainActor func theScheduleKeepsFiring() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    // The launch's own restock races the first tick, and this test reads the
    // calls as a sequence — so it is waited out first, and everything after it
    // belongs to a beat.
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    for _ in 0..<2 {
        // Parked, then released, then parked again — all on the schedule's
        // clock, so each beat is this connector's and no other loop can spend
        // one for it.
        #expect(await waitUntil { schedule.parked == 1 })
        schedule.tick()
    }
    // Waited on the FULL count, not on the second delivery. A beat is three
    // calls and the run is the middle one, so a wait that stopped at the second
    // run would read the sequence with the last restock still in flight.
    await waitUntil { host.calls.count >= 7 }

    // Two deliveries, each bracketed by a restock, after the launch's own.
    #expect(host.calls == [
        "maintain:stub",
        "maintain:stub", "run:stub", "maintain:stub",
        "maintain:stub", "run:stub", "maintain:stub",
    ])
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
    // Neither a schedule nor a launch restock: topping up a connector the user
    // switched off would be a model load and a batch of synthesis for output
    // nobody will hear.
    #expect(host.calls.contains("maintain:off") == false)
    #expect(host.calls.contains { $0.hasPrefix("run:") } == false)
    await subject.teardown()
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
    #expect(await waitUntil({ host.calls.contains("run:stub") }, limit: 0.05) == false)

    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
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
    // Waited out before the schedule is touched, for the reason
    // `theScheduleKeepsFiring` spells out: the launch restock is concurrent
    // with the first turn of the schedule, and the assertion below is on a
    // sequence.
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    await waitUntil { schedule.parked > 0 }
    subject.setIntervalPosition(1, for: connector)
    await waitUntil { schedule.durations.contains(10 * 60) }
    schedule.tick()
    // The whole beat, restock included — see `theScheduleKeepsFiring`.
    await waitUntil { host.calls.count >= 4 }

    // One tick, not two: the schedule that was sleeping five minutes is gone.
    #expect(await waitUntil(
        { host.calls.filter { $0 == "run:stub" }.count > 1 }, limit: 0.05
    ) == false)
    #expect(host.calls == [
        "maintain:stub", "maintain:stub", "run:stub", "maintain:stub",
    ])
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

    #expect(host.calls.contains("run:stub") == false)
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

    // Nothing before the run on the manual path: the restock that follows it is
    // `aManualRunRefillsWithoutWaitingForTheTimer`'s claim, and a pre-run one
    // would make pressing the button wait out a batch of synthesis.
    #expect(host.calls.first == "run:stub")
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

// The launch restock is a minute of synthesis and a whole batch of clips on a
// cold start. A quit that does not wait for it kills the process part-way
// through writing them, which is the same failure the delivery path's own
// teardown test exists for — and the launch is the one pass nobody presses a
// button to start, so nobody is watching for it either.
// Measured rather than raced. The idiom used by the two teardown tests above —
// start the teardown in a task, then assert nothing finished inside a 50 ms
// window — is only as sharp as the MainActor is idle, and with the suite run in
// parallel a teardown that returned at once could simply not be scheduled
// inside the window. This one awaits the teardown directly and times it against
// a release it did not control: a teardown that does not wait comes back before
// the release, and no amount of load can make it come back after.
@Test @MainActor func teardownWaitsForTheRestockTheLaunchStarted() async {
    let restock = Gate()
    let schedule = Metronome()
    let subject = testModel(host: SpyHost(parkInMaintain: restock), sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { restock.enteredCount == 1 })

    let started = ContinuousClock.now
    // Detached, so releasing the gate does not need the MainActor the teardown
    // is about to occupy.
    Task.detached {
        try? await Task.sleep(for: .milliseconds(200))
        restock.open()
    }
    await subject.teardown()

    #expect(ContinuousClock.now - started >= .milliseconds(150))
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

    // Two restocks park in this same gate before the tick's does: the one the
    // manual run above fires when it finishes, and the one the launch fires.
    // Both are waited out, so the third arrival can only be the tick's.
    subject.start()
    #expect(await waitUntil { schedule.parked == 1 && refill.enteredCount == 2 })
    schedule.tick()
    #expect(await waitUntil { refill.enteredCount == 3 })

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

// MARK: - Behind the gear

@MainActor
private func scratchDefaults() throws -> (UserDefaults, String) {
    let suite = "task28-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

// The rule the move was most likely to lose. There is nothing to confirm — the
// value only takes effect at the next launch — so a Save button or a submit
// would be a step the user has to discover, on a control that used to need
// neither.
@Test @MainActor func theAddressSavesAsItIsTypedWithNothingToPress() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "192.168.1.72")

    subject.typedHost = "10.0.0.9"

    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
    #expect(subject.hostNote == DeviceHostField.takesEffectNextLaunch)
}

// Every keystroke, not just the last one: a field that saved only what it was
// left holding would lose the address of anyone who types and then clicks away
// without pressing anything.
@Test @MainActor func everyChangeIsSavedRatherThanOnlyTheLast() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "192.168.1.72")

    subject.typedHost = "10.0.0"
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0")
    subject.typedHost = "10.0.0.9"
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
}

// Seeding the field is not the user typing. `didSet` does not run during
// initialization, and if it ever did, every launch would write this launch's
// address back over whatever the user had queued for the next one.
@Test @MainActor func seedingTheFieldSavesNothing() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = testModel(defaults: defaults, deviceHost: "192.168.1.72")

    #expect(subject.typedHost == "192.168.1.72")
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == nil)
    #expect(subject.hostNote == nil)
}

// A blank entry is refused, and refusing it must not report a save either.
@Test @MainActor func clearingTheFieldSavesNothingAndClaimsNothing() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "192.168.1.72")

    subject.typedHost = "10.0.0.9"
    subject.typedHost = "   "

    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
    #expect(subject.hostNote == nil)
}

// Rule 3. A settings surface is a view, not a mode: the schedule keeps its
// place, the poll keeps asking, and a delivery already under way is not
// cancelled by somebody looking at a text field.
@Test @MainActor func openingTheSettingsDoesNotDisturbAScheduledRun() async {
    let gate = Gate()
    let host = SpyHost(parkInRun: gate)
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { gate.enteredCount == 1 })

    subject.openSettings()

    // The run in flight still finishes, and the schedule takes its next turn.
    #expect(subject.lastResults["stub"] == "running…")
    gate.open()
    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(subject.settingsAreOpen)
    await subject.teardown()
}

// MARK: - When the next one is due

// The label reports the schedule's own next wake-up, read from the same answer
// the schedule sleeps on.
@Test @MainActor func theModelKnowsWhenTheNextRunIsDue() async {
    let schedule = Metronome()
    let subject = testModel(sleep: schedule.sleep)
    let asked = Date()

    subject.start()
    #expect(await waitUntil { subject.nextRun["stub"] != nil })

    guard case let .due(when) = subject.nextRun["stub"] else {
        Issue.record("expected a due time, got \(String(describing: subject.nextRun["stub"]))")
        return
    }
    // The stub's default interval is five minutes and nothing is failing.
    #expect(abs(when.timeIntervalSince(asked) - 5 * 60) < 2)
    await subject.teardown()
}

// The case a plausible implementation gets wrong, and the one the user most
// wants right: a connector that has been failing is retried SOONER than its
// interval — 30 s, then 60, then 120, capped at the interval it would otherwise
// have waited. A label computed from `ConnectorSettings.interval` would read
// five minutes while the schedule was thirty seconds away, and it would be
// wrong on exactly the occasions somebody opened the panel to ask.
@Test @MainActor func theDueTimeFollowsABackoffRatherThanTheNominalInterval() async {
    let schedule = Metronome()
    // The host answers 30 s, as it does for a connector whose last run failed.
    let subject = testModel(host: SpyHost(delay: 30), sleep: schedule.sleep)
    let asked = Date()

    subject.start()
    #expect(await waitUntil { subject.nextRun["stub"] != nil })

    guard case let .due(when) = subject.nextRun["stub"] else {
        Issue.record("expected a due time")
        return
    }
    #expect(abs(when.timeIntervalSince(asked) - 30) < 2)
    // And emphatically not the interval the settings name.
    #expect(when.timeIntervalSince(asked) < 5 * 60)
    await subject.teardown()
}

// A schedule that is held names what is holding it. Today only one thing can —
// the user switching the connector off — and three more are coming; each will
// supply its own words without this shape changing.
@Test @MainActor func aHeldScheduleSaysWhatIsHoldingItInsteadOfNamingATime() {
    let connector = StubConnector()
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: connector.id)
    let subject = testModel(connectors: [connector], store: store)

    subject.start()

    #expect(subject.nextRun["stub"] == .held(AppModel.switchedOff))
    #expect(NextRunLine.text(for: .held(AppModel.switchedOff)) == AppModel.switchedOff)
}

@Test @MainActor func aDisabledConnectorNamesNoNextTime() {
    let connector = StubConnector()
    let store = InMemorySettingsStore()
    let subject = testModel(connectors: [connector], store: store)
    subject.start()

    subject.setEnabled(false, for: connector)

    // No hour anywhere in what it says.
    let line = NextRunLine.text(for: subject.nextRun["stub"]) ?? ""
    #expect(line.contains(where: \.isNumber) == false)
}

@Test func nothingScheduledYetNamesNothing() {
    #expect(NextRunLine.text(for: nil) == nil)
}

@Test func aDueTimeIsSaidAsAnHour() {
    let when = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(
        NextRunLine.text(for: .due(when))
            == "next \(when.formatted(date: .omitted, time: .shortened))"
    )
}

// MARK: - Ten ready before the first timer fires

/// A model wired to a REAL anecdote connector and a real host, so the depth the
/// launch reaches is the connector's own answer rather than a spy's.
///
/// The two collaborators a background pass never touches are stubbed, and only
/// those: `maintain` goes queue → preparer → feed, and every step of that is
/// the shipped one.
@MainActor
private func modelWithARealAnecdoteConnector(
    feeding xml: String, schedule: Metronome
) -> (model: AppModel, queue: AnecdoteQueue) {
    let queue = AnecdoteQueue(
        storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-\(UUID().uuidString).json"),
        clipRoot: FileManager.default.temporaryDirectory,
        retention: 10 * 24 * 60 * 60
    )
    let connector = AnecdoteConnector(
        queue: queue,
        preparer: AnecdotePreparer(
            source: AnecdoteSource(transport: StubTransport(body: Data(xml.utf8))),
            speech: StubSpeechSynthesizer(),
            queue: queue
        )
    )
    let registry = ConnectorRegistry()
    registry.register(connector)
    let settings = InMemorySettingsStore()
    let device = AwtrixDevice(host: "10.0.0.5", transport: StubTransport())
    let model = AppModel(
        deviceHost: "10.0.0.5",
        device: device,
        registry: registry,
        host: ConnectorHost(
            device: device,
            registry: registry,
            store: settings,
            audio: SilentAudioPlayer(),
            iconInstaller: NoIconInstaller()
        ),
        store: settings,
        installer: CatalogueIconInstaller(
            device: device, transport: StubTransport(), uploads: InMemoryUploadedIconStore()
        ),
        defaults: UserDefaults(suiteName: "launch-\(UUID().uuidString)")!,
        sleep: schedule.sleep,
        pollSleep: parked
    )
    return (model, queue)
}

// Starting with an empty queue makes the first anecdote of the session wait on
// a 70-second model load and a synthesis, on the play path — which is the whole
// thing the queue exists to avoid. So the launch tops up before the first timer
// has ever fired.
//
// Ten, and the number is the connector's: this goes through the real
// `maintain()`, so a target of five or of one would show here.
@Test @MainActor func theAppTopsUpToTenAtLaunch() async {
    let schedule = Metronome()
    let wiring = modelWithARealAnecdoteConnector(
        feeding: anecdoteFeed(items: 12), schedule: schedule
    )

    wiring.model.start()

    #expect(await waitForQueue(wiring.queue, toReach: 10) == 10)
    // And nothing was played to get there: the schedule is still asleep on its
    // first interval, and was never released.
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await wiring.queue.hasPlayed("https://www.anekdot.ru/id/1/") == false)
    await wiring.model.teardown()
}

// A "Run now" that drains the queue must not wait for the next timer to restock
// it. `maintain` returns early above the threshold, so the extra call costs
// nothing on the passes that do not need it.
@Test @MainActor func aManualRunRefillsWithoutWaitingForTheTimer() async {
    let host = SpyHost()
    let subject = testModel(host: host)

    subject.runNow("stub")

    #expect(await waitUntil { host.calls == ["run:stub", "maintain:stub"] })
}

// And it happens AFTER the outcome is reported, not before it. A refill can be
// a minute of synthesis; a panel that waited for it would sit on `running…`
// long after the anecdote had finished playing.
@Test @MainActor func theRefillDoesNotDelayTheRunsOwnCompletion() async {
    let restock = Gate()
    let subject = testModel(host: SpyHost(parkInMaintain: restock))

    subject.runNow("stub")
    #expect(await waitUntil { restock.enteredCount == 1 })

    // The restock is parked and the panel already says how the run went.
    #expect(subject.lastResults["stub"] == "delivered")

    restock.open()
    await subject.teardown()
}

// The scheduled path gets the same treatment, and keeps Task 14's call before
// the run: a tick that only maintained afterwards would put the first firing of
// every launch back on the play path.
@Test @MainActor func aScheduledRunRestocksAfterItFinishesAsWellAsBefore() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, sleep: schedule.sleep)

    subject.start()
    // The launch top-up is a maintain of its own, and it is not the one this
    // test is about — waited out so the tick's calls stand alone after it.
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()

    #expect(await waitUntil {
        host.calls == ["maintain:stub", "maintain:stub", "run:stub", "maintain:stub"]
    })
    await subject.teardown()
}

// MARK: - What a failed restock says

// A refill that fails is invisible until a later RUN fails for the same reason,
// which can be half an hour later — and if the queue still has something to
// hand out, the run does not fail at all and the feed stays down in silence.
@Test @MainActor func aFailedRestockIsSaidOnThePanelRatherThanWaitingForARunToFail() async {
    let host = RestockReportingHost(reporting: .failed("the feed is down"))
    let subject = testModel(host: host)

    subject.runNow("stub")

    #expect(await waitUntil { subject.lastMaintenanceFailure["stub"] != nil })
    #expect(subject.lastMaintenanceFailure["stub"]?.contains("the feed is down") == true)
    // And the run's own line is untouched: two answers, two slots.
    #expect(subject.lastResults["stub"] == "delivered")
}

// The complaint has to go away again, or one bad half hour leaves the panel
// claiming a broken feed for the rest of the session.
@Test @MainActor func aRestockThatRecoversTakesTheComplaintBackDown() async {
    let host = RestockReportingHost(reporting: .failed("the feed is down"))
    let subject = testModel(host: host)

    subject.runNow("stub")
    #expect(await waitUntil { subject.lastMaintenanceFailure["stub"] != nil })

    host.nowReports(.completed)
    subject.runNow("stub")

    #expect(await waitUntil { subject.lastMaintenanceFailure["stub"] == nil })
}

// A connector the user switched off is not restocking, so it has nothing to
// complain about — and a complaint left over from when it was on describes work
// that is no longer being attempted.
@Test @MainActor func aConnectorThatIsNoLongerRestockingHasNoComplaintToMake() async {
    let host = RestockReportingHost(reporting: .failed("the feed is down"))
    let subject = testModel(host: host)

    subject.runNow("stub")
    #expect(await waitUntil { subject.lastMaintenanceFailure["stub"] != nil })

    host.nowReports(.skipped)
    subject.runNow("stub")

    #expect(await waitUntil { subject.lastMaintenanceFailure["stub"] == nil })
}

// Cancellation is the one answer that changes nothing. Its ordinary producer is
// a quit part-way through a fetch, which says nothing about whether the feed is
// up — clearing a real outage on the strength of having been interrupted is the
// same mistake as recording one because of it.
@Test @MainActor func aRestockCutOffByAQuitLeavesTheComplaintWhereItWas() async {
    let host = RestockReportingHost(reporting: .failed("the feed is down"))
    let subject = testModel(host: host)

    subject.runNow("stub")
    #expect(await waitUntil { subject.lastMaintenanceFailure["stub"] != nil })

    host.nowReports(.cancelled)
    subject.runNow("stub")
    // Teardown is both the rendezvous and the scenario: it waits for the run it
    // is cutting short, so by the time it returns the cancelled pass has
    // certainly been recorded.
    //
    // Waiting on a call counter in the double does NOT do, and this test passed
    // for that reason before a mutation caught it. The counter moves inside
    // `maintain`, one continuation before the answer is written down, and a
    // check that raced into that gap read the previous pass's line and called
    // it survival — green against an implementation that cleared it.
    await subject.teardown()

    #expect(subject.lastMaintenanceFailure["stub"]?.contains("the feed is down") == true)
}
