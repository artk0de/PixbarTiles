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
    let metronome = Metronome()
    let subject = testModel(host: host, sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.durations.contains(5 * 60) }

    // Launching the app reschedules every connector. Firing on the spot would
    // put an anecdote on the clock at every launch, which nobody asked for.
    #expect(host.calls.isEmpty)
    await subject.teardown()
}

@Test @MainActor func aScheduleSleepsTheConnectorsOwnInterval() async {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let metronome = Metronome()
    let subject = testModel(connectors: [connector], sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.durations.contains(5 * 60) }

    #expect(metronome.durations.contains(5 * 60))
    await subject.teardown()
}

// The whole reason the background pass has its own entry point. `produce()`
// only awaits a refill when the queue is empty, so a tick that never maintains
// turns every firing into a 70-second model load on the play path.
@Test @MainActor func everyTickMaintainsBeforeItRuns() async {
    let host = SpyHost()
    let metronome = Metronome()
    let subject = testModel(host: host, sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.parked > 0 }
    metronome.tick()
    await waitUntil { host.calls.count >= 2 }

    #expect(host.calls == ["maintain:stub", "run:stub"])
    await subject.teardown()
}

@Test @MainActor func theScheduleKeepsFiring() async {
    let host = SpyHost()
    let metronome = Metronome()
    let subject = testModel(host: host, sleep: metronome.sleep)

    subject.start()
    for _ in 0..<2 {
        await waitUntil { metronome.parked > 0 }
        metronome.tick()
        await waitUntil { metronome.parked > 0 }
    }
    await waitUntil { host.calls.count >= 4 }

    #expect(host.calls == ["maintain:stub", "run:stub", "maintain:stub", "run:stub"])
    await subject.teardown()
}

@Test @MainActor func aDisabledConnectorIsNeverScheduled() async {
    let connector = StubConnector()
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: connector.id)
    let host = SpyHost()
    let metronome = Metronome()
    let subject = testModel(connectors: [connector], host: host, store: store, sleep: metronome.sleep)

    subject.start()
    // Nothing to wait for, so the assertion is that nothing ever starts one.
    // The poll's own sleep is the only one there should be: a disabled
    // connector does not even reach an interval.
    #expect(await waitUntil({ metronome.durations.count > 1 }, limit: 0.05) == false)

    #expect(metronome.durations == [AppModel.monitorInterval])
    #expect(host.calls.isEmpty)
}

@Test @MainActor func switchingAConnectorOffStopsItsSchedule() async {
    let connector = StubConnector()
    let host = SpyHost()
    let metronome = Metronome()
    let subject = testModel(connectors: [connector], host: host, sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.parked > 0 }
    subject.setEnabled(false, for: connector)
    // The schedule is gone, so releasing whatever was parked releases a sleep
    // nobody is looping on any more.
    metronome.tick()
    #expect(await waitUntil({ host.calls.isEmpty == false }, limit: 0.05) == false)

    #expect(host.calls.isEmpty)
}

// Changing the interval has to replace the schedule, not add to it. The
// interval is read once when the loop starts, so a schedule left running keeps
// firing on the old one — and both then fire, for ever.
@Test @MainActor func changingTheIntervalReplacesTheScheduleRatherThanAddingOne() async {
    let connector = StubConnector(defaultInterval: 5 * 60)
    let host = SpyHost()
    let metronome = Metronome()
    let subject = testModel(connectors: [connector], host: host, sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.parked > 0 }
    subject.setIntervalPosition(1, for: connector)
    await waitUntil { metronome.durations.contains(10 * 60) }
    metronome.tick()
    await waitUntil { host.calls.count >= 2 }

    // One tick, not two: the schedule that was sleeping five minutes is gone.
    #expect(await waitUntil({ host.calls.count > 2 }, limit: 0.05) == false)
    #expect(host.calls == ["maintain:stub", "run:stub"])
    #expect(metronome.durations.contains(10 * 60))
    await subject.teardown()
}

// A cancelled sleep is the quit path. Swallowing the throw and carrying on
// would start one more delivery while the app is being torn down — a banner put
// on the clock by the very act of quitting.
@Test @MainActor func aCancelledScheduleDoesNotStartOneLastRun() async {
    let host = SpyHost()
    let metronome = Metronome()
    let subject = testModel(host: host, sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.parked > 0 }
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
    let metronome = Metronome()
    let subject = testModel(host: host, sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.parked > 0 }
    metronome.tick()
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
    let metronome = Metronome()
    let subject = testModel(host: SpyHost(parkInRun: gate), sleep: metronome.sleep)

    subject.start()
    await waitUntil { metronome.parked > 0 }
    metronome.tick()
    await waitUntil { gate.enteredCount == 1 }

    #expect(subject.lastResults["stub"] == "running…")
    gate.open()
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
    let metronome = Metronome()
    let subject = testModel(transport: StubTransport(body: onlineStats), sleep: metronome.sleep)

    #expect(subject.isDeviceOnline == false)
    subject.start()

    #expect(await waitUntil({ subject.isDeviceOnline }))
    await subject.teardown()
}

@Test @MainActor func aDeviceThatCannotBeReachedLeavesTheGlyphUnlit() async {
    let metronome = Metronome()
    let subject = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)), sleep: metronome.sleep
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

    await subject.removeInstalledIcons()

    let deletions = transport.requests.filter { $0.httpMethod == "DELETE" }
    #expect(deletions.count == 1)
    let body = String(decoding: deletions.first?.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("/ICONS/9039.gif"))
    #expect(subject.iconStatus == "removed 9039")
}

@Test @MainActor func removingNothingSaysSoRatherThanClaimingSuccess() async {
    let transport = StubTransport()
    let subject = testModel(transport: transport)

    await subject.removeInstalledIcons()

    #expect(transport.requests.isEmpty)
    #expect(subject.iconStatus == "nothing this app uploaded")
}

@Test @MainActor func aRemovalTheDeviceRefusesIsReportedRatherThanSwallowed() async {
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = testModel(
        transport: StubTransport(status: 500, body: Data("boom".utf8)), uploads: uploads
    )

    await subject.removeInstalledIcons()

    let status = subject.iconStatus ?? ""
    #expect(status.hasPrefix("failed:"))
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
