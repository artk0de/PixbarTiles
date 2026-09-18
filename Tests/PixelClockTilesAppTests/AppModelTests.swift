import AppKit
import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

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

// MARK: - What the launch puts in the clock's loop

// A custom app is furniture rather than an event. The clock has none of it
// until this app has been running for a whole cadence — measured on the
// hardware at sixteen minutes of a blank slot after a launch — and once a
// `lifetime` is on the output, an app that expired during a long sleep stays
// expired for a cadence more. An anecdote is the opposite case, and the reason
// the sleep-first rule exists: relaunching must not shout one at whoever just
// logged in. `isAmbient` is what tells the two apart.
//
// Both connectors in ONE model, on one launch, so "delivered" and "did not" are
// the same event rather than two runs of a suite. Nothing is ticked: the whole
// claim is a delivery that happens before any interval has elapsed.
@Test @MainActor func theLaunchPutsAnAmbientConnectorInTheLoopAndLeavesTheRestAsleep() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [ambientConnector, StubConnector()], host: host, sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { host.calls.contains("run:ambient") })
    // Both loops asleep on their first interval, so the silence of the second
    // connector is a schedule that exists and has not fired — rather than one
    // that was never built, which would prove nothing at all.
    #expect(await waitUntil { schedule.parked == 2 })

    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// A launch is not a licence to write to a device that is not answering, so the
// unreachable clock that holds a beat holds this too. What differs is what
// happens next: a beat declined is followed by another one a cadence later,
// while the launch has no successor — so the delivery is KEPT and spent on the
// first poll that finds the clock there.
//
// Driven on the poll's own clock, which is the loop that learns the difference.
// The schedule is left parked for a day, so the delivery this reads can only be
// the launch's.
@Test @MainActor func theLaunchDeliveryIsKeptWhileTheClockIsNotAnsweringAndGoesOutWhenItDoes()
    async
{
    let host = SpyHost()
    let poll = Metronome()
    let clock = SwitchableTransport(answering: false)
    let subject = testModel(
        connectors: [ambientConnector], host: host, transport: clock, pollSleep: poll.sleep
    )

    subject.start()
    // The poll has ANSWERED, rather than merely not been asked yet: the
    // decision this test is about is made on that answer, in the same turn.
    #expect(await waitUntil { isOffline(subject) })
    #expect(host.calls.contains("run:ambient") == false)

    clock.nowAnswers()
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()

    #expect(await waitUntil { host.calls.contains("run:ambient") })
    await subject.teardown()
}

// One extra delivery, not one instead. The schedule beside it is still asleep
// on its own full interval, so the first beat lands one cadence after the
// launch rather than two — which is what a launch that spent the beat, or
// restarted the loop after delivering, would cost.
@Test @MainActor func theLaunchDeliveryDoesNotSpendTheFirstScheduledBeat() async {
    let connector = StubConnector(
        id: "ambient",
        displayName: "Ambient",
        defaultInterval: 600,
        isAudible: false,
        isAmbient: true
    )
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(connectors: [connector], host: host, sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { host.calls.contains("run:ambient") })
    #expect(await waitUntil { schedule.parked == 1 })

    // One wait asked for, and it is the connector's own: the launch delivery
    // neither shortened it nor consumed a turn of the loop.
    #expect(schedule.durations == [600])
    schedule.tick()

    #expect(await waitUntil { host.calls.filter { $0 == "run:ambient" }.count == 2 })
    await subject.teardown()
}

// MARK: - A relaunch resumes the schedule rather than restarting it

// Measured on the hardware: an hourly connector, the app last started at
// 16:07:49, so the first anecdote was due at 17:07:49 — and it had been
// relaunched five times inside the preceding hour, each relaunch pushing that
// first delivery a whole hour further out. Somebody who quits and reopens now
// and then never hears one at all.
//
// The sleep-first rule is not what was wrong and is not weakened here. What was
// missing is the memory of when this connector last delivered, so the elapsed
// time counts against the wait and the app owes the remainder of it rather than
// the whole of it again.
@Test @MainActor func aRelaunchWaitsOutWhatIsLeftOfTheIntervalRatherThanAWholeOneAgain()
    async throws
{
    let store = InMemorySettingsStore()
    // Position 11 is the hour, and it is the position the reported defect was
    // measured at rather than a round number picked to read well.
    store.save(
        ConnectorSettings(
            intervalPosition: 11, lastDeliveredAt: Date().addingTimeInterval(-55 * 60)
        ),
        for: "stub"
    )
    let schedule = Metronome()
    let subject = testModel(store: store, sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { schedule.durations.isEmpty == false })

    // About five minutes rather than exactly five: the remainder is measured
    // against a wall clock this test cannot stop. A clock injected for the sake
    // of this one line would be a seam in the model that nothing else wants.
    let first = try #require(schedule.durations.first)
    #expect(abs(first - 5 * 60) < 5)
    await subject.teardown()
}

// The other half of the same rule, and the reason a missing instant is not
// folded into a zero: a connector with nothing behind it owes no remainder, so
// it waits the whole cadence exactly as it did before any of this. Firing at
// launch instead is what the sleep-first rule was put there to prevent.
@Test @MainActor func aConnectorThatHasNeverDeliveredStillWaitsAWholeInterval() async {
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(intervalPosition: 11), for: "stub")
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, store: store, sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { schedule.durations == [60 * 60] })

    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// A gap longer than the interval owes ONE delivery. Four anecdotes queued up
// for having closed the laptop over lunch is a punishment rather than a
// catch-up, and it is the choice this branch has already made twice: a meeting
// that swallows four beats releases one, and an outage that swallows six
// replays none of them.
//
// Two claims, and the second is what "resume the cadence" means: the remainder
// is clamped at zero rather than left negative, and the beat after the overdue
// one asks for a whole interval again rather than another nothing.
@Test @MainActor func aGapOfSeveralIntervalsOwesOneDeliveryRatherThanAQueueOfThem() async {
    let store = InMemorySettingsStore()
    store.save(
        ConnectorSettings(
            intervalPosition: 11, lastDeliveredAt: Date().addingTimeInterval(-5 * 60 * 60)
        ),
        for: "stub"
    )
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(host: host, store: store, sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { schedule.durations == [0] })
    // Released here rather than arriving on its own, because that is the claim:
    // an overdue relaunch reaches its delivery through the sleep and the tick,
    // where every hold the schedule answers to is asked of it unchanged.
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.durations == [0, 60 * 60] })

    #expect(host.calls.filter { $0 == "run:stub" } == ["run:stub"])
    await subject.teardown()
}

// Dragging the slider rebuilds the schedule, and the rebuilt one starts from
// NOW. The remembered instant belongs to the launch and is spent by it: a
// resume that survived into a settings change would fire a delivery on the
// gesture `commit` rules out in as many words, and switching a connector on
// would deliver the moment its switch moved.
@Test @MainActor func draggingTheSliderReschedulesFromNowRatherThanFromTheRememberedInstant()
    async
{
    let connector = StubConnector()
    let store = InMemorySettingsStore()
    store.save(
        ConnectorSettings(
            intervalPosition: 11, lastDeliveredAt: Date().addingTimeInterval(-55 * 60)
        ),
        for: connector.id
    )
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [connector], host: host, store: store, sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.durations.count == 1 })
    subject.setIntervalPosition(5, for: connector)
    #expect(await waitUntil { schedule.durations.count == 2 })

    // Everything after the launch's own wait is the half hour just chosen,
    // with nothing subtracted from it.
    #expect(Array(schedule.durations.dropFirst()) == [30 * 60])
    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// What the next launch reads, written by the run that earned it. Beside the
// interval rather than in a store of its own: one key per connector, one shape
// to decode, and nothing that can fall out of step with the settings the slider
// writes through the same path.
@Test @MainActor func aDeliveryIsWrittenDownWhereTheNextLaunchWillReadIt() async throws {
    let connector = StubConnector()
    let store = InMemorySettingsStore()
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [connector], host: host, store: store, sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { store.storedSettings(for: connector.id)?.lastDeliveredAt != nil })

    let delivered = try #require(store.storedSettings(for: connector.id)?.lastDeliveredAt)
    // The instant of the delivery, not of the launch that scheduled it.
    #expect(abs(delivered.timeIntervalSinceNow) < 5)
    await subject.teardown()
}

// The weather is the connector this deliberately does NOT apply to, and stating
// why is the point: an ambient connector is already delivered at launch, on the
// first poll that finds the clock answering. Resuming would owe it a second
// delivery seconds after the first, and the schedule's copy would go out while
// the device state is still `.unknown` — the write `deliverWhatTheLaunchOwes`
// exists to refuse. One launch owes one delivery per connector; `isAmbient` is
// what decides which of the two mechanisms pays it.
@Test @MainActor func anAmbientConnectorIsLeftToItsLaunchDeliveryRatherThanAlsoResuming() async {
    let store = InMemorySettingsStore()
    store.save(
        ConnectorSettings(
            intervalPosition: 11, lastDeliveredAt: Date().addingTimeInterval(-5 * 60 * 60)
        ),
        for: ambientConnector.id
    )
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [ambientConnector], host: host, store: store, sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { host.calls.contains("run:ambient") })

    // The whole hour the settings name, rather than the nothing an overdue
    // resume would have asked for.
    #expect(await waitUntil { schedule.durations == [60 * 60] })
    #expect(host.calls.filter { $0 == "run:ambient" } == ["run:ambient"])
    await subject.teardown()
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

// MARK: - How often, and who else can ask

@Test @MainActor func theClockIsAskedHowItIsOnceAMinute() async {
    let poll = Metronome()
    let subject = testModel(transport: StubTransport(body: onlineStats), pollSleep: poll.sleep)

    subject.start()

    // Read off the interval the loop actually asked its clock for, rather than
    // off the constant: a poll that slept on a number of its own would leave an
    // assertion about `monitorInterval` green while shipping three requests a
    // minute.
    #expect(await waitUntil { poll.durations.isEmpty == false })
    #expect(poll.durations.first == 60)
    await subject.teardown()
}

@Test @MainActor func openingThePanelTakesAReadingRatherThanShowingAMinuteOldOne() async {
    let poll = Metronome()
    let clock = ScriptedTransport(bodies: [statsBody(percent: 80, raw: 800)])
    let subject = testModel(transport: clock, pollSleep: poll.sleep)
    subject.start()
    #expect(await waitUntil { poll.parked == 1 })
    #expect(clock.responses == 1)

    subject.refreshOnPanelOpen()

    #expect(await waitUntil { clock.responses == 2 })
    // And the poll was not restarted to get it. A refresh spelled
    // `startMonitoring()` would answer this file's other reachability tests
    // just as well, while leaving two loops asking the clock — measurable here
    // as a second sleeper, and on the desk as a doubling every time the panel
    // is opened.
    #expect(poll.durations.count == 1)
    #expect(poll.parked == 1)
    await subject.teardown()
}

@Test @MainActor func twoOpensInASecondAreOneReadingRatherThanTwo() async {
    let poll = Metronome()
    let clock = ScriptedTransport(bodies: [statsBody(percent: 80, raw: 800)])
    let subject = testModel(transport: clock, pollSleep: poll.sleep)
    subject.start()
    #expect(await waitUntil { poll.parked == 1 })

    // Closed and opened again, or a SwiftUI rebuild handing the same panel a
    // second `.onAppear`. Neither is a second question worth asking the clock.
    subject.refreshOnPanelOpen()
    subject.refreshOnPanelOpen()

    // Teardown waits for whatever the opens started, so this counts what
    // actually went out rather than what had gone out by the time it looked.
    await subject.teardown()

    #expect(clock.responses == 2)
}

// MARK: - Battery warnings

@Test @MainActor func aThresholdCrossedByThePollReachesTheAlert() async {
    let alerts = SpyAlerts()
    let poll = Metronome()
    let subject = testModel(
        transport: ScriptedTransport(
            // Either side of the twenty line on this clock's MEASURED curve —
            // 604 is thirty-two percent and 597 is nineteen. The 547-to-511
            // these used to be sit below the voltage it was measured to die on,
            // so they are all zero now and crossed the last line, not the first.
            bodies: (0...25).map { statsBody(percent: 25, raw: 604 - $0 / 4) }
                + [statsBody(percent: 25, raw: 598), statsBody(percent: 19, raw: 597)]
        ),
        pollSleep: poll.sleep,
        alerts: alerts
    )

    // Twenty-six minutes of discharge fed in before the loop starts, at
    // instants ending just before now. The warnings are gated on a direction,
    // a fall is a line fitted across an hour and is not believed off less than
    // twenty minutes of it, and the poll takes its own instant off the wall
    // clock — so two ticks a millisecond apart establish nothing on their own
    // and no crossing could ever reach the alert.
    let base = Date()
    for minute in 0...25 {
        await subject.monitor.refresh(at: base.addingTimeInterval(Double(minute - 26) * 60))
    }

    subject.start()
    // The first poll parked, so the first reading has landed. It crosses
    // nothing: 25% is a long way above the first line.
    #expect(await waitUntil { poll.parked == 1 })
    #expect(alerts.warnings.isEmpty)

    poll.tick()

    #expect(await waitUntil { alerts.warnings.count == 1 })
    #expect(alerts.warnings.first?.threshold == 20)
    #expect(alerts.warnings.first?.percent == 19)
    await subject.teardown()
}

@Test @MainActor func aPollThatCrossesNothingRaisesNothing() async {
    let alerts = SpyAlerts()
    let poll = Metronome()
    let subject = testModel(
        // Falling, and nowhere near a threshold. The wiring must pass on what
        // the trajectory answers rather than warning on every reading.
        transport: ScriptedTransport(
            bodies: [statsBody(percent: 80, raw: 800), statsBody(percent: 79, raw: 790)]
        ),
        pollSleep: poll.sleep,
        alerts: alerts
    )

    subject.start()
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()
    #expect(await waitUntil { poll.durations.count == 2 })

    #expect(alerts.warnings.isEmpty)
    await subject.teardown()
}

@Test @MainActor func aTornDownPollStopsAskingTheClockAnything() async {
    let poll = Metronome()
    let clock = ScriptedTransport(bodies: [statsBody(percent: 80, raw: 800)])
    let subject = testModel(transport: clock, pollSleep: poll.sleep, alerts: SpyAlerts())
    subject.start()
    #expect(await waitUntil { poll.parked == 1 })

    await subject.teardown()
    let asked = clock.responses

    // Released after the cancel. A loop that neither returns on the throw nor
    // rechecks cancellation does not stop — it spins, because a cancelled sleep
    // throws the moment it is entered, and every turn of it is another request
    // at a clock the app is in the middle of walking away from. And, since this
    // poll is now what raises the battery dialog, another chance to put one on
    // screen during a quit.
    poll.tick()

    #expect(await waitUntil({ clock.responses > asked }, limit: 0.1) == false)
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

    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
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
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0")
    subject.typedHost = "10.0.0.9"
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
}

// Seeding the field is not the user typing. `didSet` does not run during
// initialization, and if it ever did, every launch would write this launch's
// address back over whatever the user had queued for the next one.
@Test @MainActor func seedingTheFieldSavesNothing() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = testModel(defaults: defaults, deviceHost: "192.168.1.72")

    #expect(subject.typedHost == "192.168.1.72")
    #expect(ClockStore(defaults: defaults).all().isEmpty)
    #expect(subject.hostNote == nil)
}

// A blank entry is refused, and refusing it must not report a save either.
@Test @MainActor func clearingTheFieldSavesNothingAndClaimsNothing() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "192.168.1.72")

    subject.typedHost = "10.0.0.9"
    subject.typedHost = "   "

    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
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
    let answered = Date()

    guard case let .due(when) = subject.nextRun["stub"] else {
        Issue.record("expected a due time, got \(String(describing: subject.nextRun["stub"]))")
        return
    }
    // The stub's default interval is five minutes and nothing is failing.
    //
    // Bracketed between the two instants rather than measured against a
    // tolerance. The schedule computes its due time from whenever it got to run,
    // which on a suite sharing one main actor with several hundred other tests
    // is up to a few seconds after the call — and a tolerance wide enough to
    // cover that is one that no longer says which interval was used.
    #expect(when >= asked.addingTimeInterval(5 * 60))
    #expect(when <= answered.addingTimeInterval(5 * 60))
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
    let answered = Date()

    guard case let .due(when) = subject.nextRun["stub"] else {
        Issue.record("expected a due time")
        return
    }
    // Bracketed for the reason `theModelKnowsWhenTheNextRunIsDue` brackets: the
    // schedule computes this from whenever it got to run, and on a loaded main
    // actor that is seconds rather than milliseconds after the call.
    #expect(when >= asked.addingTimeInterval(30))
    #expect(when <= answered.addingTimeInterval(30))
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

// A row the user has switched off keeps saying so, even when its old schedule
// is still in the middle of asking how long to wait.
//
// The question is asked across an await, and `reschedule` writes `off` and
// cancels the timer while the answer is in flight. The cancelled turn still
// comes back and still has a time in its hand, and publishing it there would put
// an hour on a row that is never going to run — the one label a live clock must
// not be allowed to overwrite.
//
// The metronome is the positive evidence rather than a quiet interval: the
// resumed turn reaches its sleep, which records the duration it asked for, so
// the assertion below is made after the dangerous moment has demonstrably
// passed.
@Test @MainActor func aConnectorSwitchedOffWhileItsScheduleIsAskingKeepsSayingOff() async {
    let gate = Gate()
    let schedule = Metronome()
    let connector = StubConnector()
    let subject = testModel(
        connectors: [connector], host: SpyHost(parkInDelay: gate), sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { gate.enteredCount == 1 })
    subject.setEnabled(false, for: connector)
    #expect(subject.nextRun["stub"] == .held(AppModel.switchedOff))

    gate.open()

    // The turn that was parked has come all the way back and reached its sleep.
    #expect(await waitUntil { schedule.durations.isEmpty == false })
    #expect(subject.nextRun["stub"] == .held(AppModel.switchedOff))
    await subject.teardown()
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
        clock: ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5"),
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
        alerts: SpyAlerts(),
        focus: focusGate(StubFocusStatus(access: .authorized)),
        microphone: MicrophoneGate(inputs: StubAudioInputs()),
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

// MARK: - History

// The day as well as the hour. History reaches back ten days, and "14:32" on
// its own answers "what was that one this morning" only if it was this morning
// — for anything older it is the day that is being asked about.
@Test func aPlayedMomentIsSaidAsADayAndAnHour() {
    let moment = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let said = PlayedAtLine.text(for: moment)
    let hourAlone = moment.formatted(date: .omitted, time: .shortened)

    #expect(said.contains(hourAlone))
    #expect(said != hourAlone)
}

/// A store file whose history is exactly these entries, oldest first, as an
/// earlier launch would have left it.
///
/// Written rather than retired into a live queue, because `retire` stamps
/// `Date()` and a test cannot ask it for an entry from last week — which is the
/// only kind the retention window has anything to say about.
private func storeHolding(history entries: [PlayedAnecdote]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let encoded = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
    try Data(#"{"pending":[],"played":[],"history":\#(encoded)}"#.utf8).write(to: url)
    return url
}

/// The real connector over a queue holding exactly `entries`, with the reaper
/// already run against `now`.
@MainActor
private func historyAfterReaping(
    _ entries: [PlayedAnecdote], at now: Date, retention: TimeInterval
) async throws -> (connector: AnecdoteConnector, reaped: Int) {
    let queue = AnecdoteQueue(
        storeURL: try storeHolding(history: entries),
        clipRoot: FileManager.default.temporaryDirectory,
        retention: retention
    )
    let connector = AnecdoteConnector(
        queue: queue,
        preparer: AnecdotePreparer(
            source: AnecdoteSource(transport: StubTransport()),
            speech: StubSpeechSynthesizer(),
            queue: queue
        )
    )
    return (connector, await queue.reapExpired(now: now))
}

// What the menu lists is what the queue still holds: newest first, and bounded
// by the retention window the reaper enforces — not by a count of its own. A
// second limit here would be a second answer to a question Task 17 already
// answers, and the two would disagree the first time either moved.
@Test @MainActor func historyListsNewestFirstAndStopsAtTheRetentionWindow() async throws {
    let retention: TimeInterval = 10 * 24 * 60 * 60
    let now = Date()
    let wiring = try await historyAfterReaping(
        [
            PlayedAnecdote(
                anecdote: anecdoteWhoseClipsAreGone(id: "old", text: "eleven days ago"),
                playedAt: now.addingTimeInterval(-retention - 60)
            ),
            PlayedAnecdote(
                anecdote: anecdoteWhoseClipsAreGone(id: "middle", text: "two days ago"),
                playedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
            ),
            PlayedAnecdote(
                anecdote: anecdoteWhoseClipsAreGone(id: "newest", text: "an hour ago"),
                playedAt: now.addingTimeInterval(-60 * 60)
            ),
        ],
        at: now,
        retention: retention
    )
    // The one past the window went, and only it.
    #expect(wiring.reaped == 1)

    let subject = testModel(anecdotes: wiring.connector)
    subject.openHistory()

    #expect(await waitUntil { subject.history?.isEmpty == false })
    #expect(subject.history?.map(\.anecdote.id) == ["newest", "middle"])
}

// Rule three. The record survives its audio — it is still listed and still
// copyable — but there is nothing left to play, and a "Play again" that puts a
// held banner on the clock with no audio to end it leaves the banner up until
// somebody walks over and presses the middle button.
//
// The playable one is what makes the silence above a refusal rather than a
// replay that has simply not happened yet.
@Test @MainActor func anEntryWithMissingClipsCannotBeReplayed() async throws {
    let host = SpyHost()
    let here = try playableAnecdote(id: "here", text: "still here")
    let gone = anecdoteWhoseClipsAreGone(id: "gone", text: "long gone")
    let subject = testModel(
        host: host,
        anecdotes: StubAnecdotes(history: [
            PlayedAnecdote(anecdote: gone, playedAt: Date()),
            PlayedAnecdote(anecdote: here, playedAt: Date()),
        ])
    )

    subject.replay(gone)
    subject.replay(here)

    #expect(await waitUntil { host.calls.contains("deliver:still here") })
    #expect(host.calls.filter { $0.hasPrefix("deliver:") } == ["deliver:still here"])
}

// Rule four: the joke, not the banner. What the clock shows is
// "ВНИМАНИЕ, АНЕКДОТ!" and what the laughter marker holds is "АХАХАХА" —
// neither is what somebody pressing Copy is trying to paste into a chat.
//
// The entry copied here has no audio left, which is the other half of rule
// three: an anecdote whose clips are gone is still copyable.
@Test @MainActor func copyingPutsTheAnecdoteTextOnThePasteboard() {
    let board = NSPasteboard(name: NSPasteboard.Name("awtrix-copy-\(UUID().uuidString)"))
    let subject = testModel(pasteboard: board)
    let anecdote = anecdoteWhoseClipsAreGone(id: "x", text: "Заходит улитка в бар")

    subject.copyText(anecdote)

    #expect(board.string(forType: .string) == "Заходит улитка в бар")
}

// Rule one, from the app's side. A replay goes to `deliver`, which is not a
// run: nothing is produced, nothing is retired, and — the part this test is
// about — no restock follows it and the connector's own result line is left
// alone. Replaying something from last week must not touch tomorrow's schedule.
//
// The run at the end is the control: the same spy records both, so the absence
// above is a refusal to run rather than a spy that cannot see one.
@Test @MainActor func aReplayIsNeitherARunNorARestock() async throws {
    let host = SpyHost()
    let here = try playableAnecdote(id: "here", text: "still here")
    let subject = testModel(
        host: host,
        anecdotes: StubAnecdotes(history: [PlayedAnecdote(anecdote: here, playedAt: Date())])
    )

    subject.replay(here)

    #expect(await waitUntil { host.calls == ["deliver:still here"] })
    #expect(subject.lastResults["stub"] == nil)

    subject.runNow("stub")

    #expect(await waitUntil {
        host.calls == ["deliver:still here", "run:stub", "maintain:stub"]
    })
}

// A replay puts the same held banner on the clock as a run, so the quit has to
// wait for it too: a process killed during the release leaves the clock on that
// banner. The task is the button's unless the model owns it, and teardown
// cannot wait for something it does not hold.
//
// Measured against a release it does not control rather than raced inside a
// 50 ms window: a teardown that does not wait comes back before the release,
// and no amount of load can make it come back after.
@Test @MainActor func teardownWaitsForAReplay() async throws {
    let gate = Gate()
    let here = try playableAnecdote(id: "here", text: "still here")
    let subject = testModel(
        host: SpyHost(parkInDeliver: gate),
        anecdotes: StubAnecdotes(history: [PlayedAnecdote(anecdote: here, playedAt: Date())])
    )

    subject.replay(here)
    #expect(await waitUntil { gate.enteredCount == 1 })

    let started = ContinuousClock.now
    // Detached, so releasing the gate does not need the MainActor the teardown
    // is about to occupy.
    Task.detached {
        try? await Task.sleep(for: .milliseconds(200))
        gate.open()
    }
    await subject.teardown()

    #expect(ContinuousClock.now - started >= .milliseconds(150))
}

// MARK: - Paused while the clock is unreachable

// What the pause is worth, and why it is not housekeeping: `produce()` pops an
// anecdote and retires it BEFORE the banner goes out, so every retry against a
// clock that is not answering permanently spends something the user never
// hears. With the backoff shortening the retries that is about six over a
// half-hour outage rather than one, and the queue is dragged under its refill
// threshold on top. Not running at all is the fix.
//
// The control is what makes this a test about the OUTAGE. Two models alike in
// everything — same connector, same spy, same beat — except that one clock
// answers and the other does not: the reachable one delivers on the very beat
// the unreachable one declines. So "no run" cannot be a schedule that was never
// built, a connector that was switched off, or a tick that never arrived.
@Test @MainActor func theScheduleDoesNotRunConnectorsWhileTheDeviceIsOffline() async {
    let unreachableHost = SpyHost()
    let unreachableSchedule = Metronome()
    let unreachable = testModel(
        host: unreachableHost,
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        sleep: unreachableSchedule.sleep
    )
    let answeringHost = SpyHost()
    let answeringSchedule = Metronome()
    let answering = testModel(
        host: answeringHost,
        transport: StubTransport(body: onlineStats),
        sleep: answeringSchedule.sleep
    )

    unreachable.start()
    answering.start()
    // Both polls have answered, so what the gate reads is the state under test
    // rather than the one every model starts in.
    #expect(await waitUntil { isOffline(unreachable) })
    #expect(await waitUntil { answering.isDeviceOnline })
    // The launch's own restock, waited out on both, so everything after it
    // belongs to the beat.
    #expect(await waitUntil { unreachableHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { answeringHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { unreachableSchedule.parked == 1 })
    #expect(await waitUntil { answeringSchedule.parked == 1 })

    unreachableSchedule.tick()
    answeringSchedule.tick()

    #expect(await waitUntil { answeringHost.calls.contains("run:stub") })
    // Waited on the BEAT BEING OVER — the loop asleep again on the next
    // interval — rather than on a call count. A count of two is reached
    // half-way through an ungated tick as well, between its restock and its
    // run, and a test that read the log there would find no delivery yet and
    // pass while the delivery was one continuation away.
    #expect(await waitUntil { unreachableSchedule.parked == 1 })
    #expect(unreachableHost.calls == ["maintain:stub", "maintain:stub"])
    #expect(unreachableHost.calls.contains("run:stub") == false)
    await unreachable.teardown()
    await answering.teardown()
}

// Nothing about the pause is sticky. The timer keeps its beat and the poll
// keeps asking, so the first beat after the clock answers delivers — there is
// no state to clear and nothing to wait for beyond the poll itself.
@Test @MainActor func theScheduleResumesAsSoonAsTheDeviceAnswers() async {
    let host = SpyHost()
    let schedule = Metronome()
    let poll = Metronome()
    let clock = SwitchableTransport(answering: false)
    let subject = testModel(
        host: host, transport: clock, sleep: schedule.sleep, pollSleep: poll.sleep
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    // The beat is over — asleep again — before the log is read, or the absence
    // of a delivery is only the absence of one YET.
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    clock.nowAnswers()
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()
    #expect(await waitUntil { subject.isDeviceOnline })

    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    await subject.teardown()
}

// A pause is not a failure. The backoff describes how the FEED is behaving, and
// a clock that is not answering says nothing about anekdot.ru — a count that
// grew through an outage would have a healthy connector retrying every thirty
// seconds the moment the clock came back.
//
// Read off the shipped host's own count rather than a spy's, and with the
// control in the same test: the manual run at the end goes through the same
// wiring against the same unreachable clock and DOES move the count, so the
// zero above is the schedule declining to run rather than a counter nothing
// here can reach.
@Test @MainActor func anOfflinePauseDoesNotAdvanceTheFailureCounter() async {
    let schedule = Metronome()
    let wiring = modelOverRealHost(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)), sleep: schedule.sleep
    )

    wiring.model.start()
    #expect(await waitUntil { isOffline(wiring.model) })
    #expect(await waitUntil { schedule.parked == 1 })
    for _ in 0..<3 {
        schedule.tick()
        #expect(await waitUntil { schedule.parked == 1 })
    }

    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 0)

    wiring.model.runNow("stub")

    #expect(await waitUntil { wiring.model.lastResults["stub"]?.hasPrefix("failed:") == true })
    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 1)
    await wiring.model.teardown()
}

// And not a success either. A backoff a genuinely broken feed earned has to
// survive the outage that follows it: resuming into a cleared count would have
// the app deliver nothing and say nothing was wrong.
@Test @MainActor func anOfflinePauseDoesNotResetAnEarnedBackoff() async {
    let schedule = Metronome()
    let poll = Metronome()
    let clock = SwitchableTransport()
    let wiring = modelOverRealHost(
        connector: BrokenConnector(), transport: clock, sleep: schedule.sleep, pollSleep: poll.sleep
    )

    wiring.model.start()
    #expect(await waitUntil { wiring.model.isDeviceOnline })
    // Earned against a clock that IS answering, so the failure is the feed's.
    wiring.model.runNow("stub")
    #expect(await waitUntil { wiring.model.lastResults["stub"]?.hasPrefix("failed:") == true })
    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 1)

    clock.nowFails()
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()
    #expect(await waitUntil { isOffline(wiring.model) })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })

    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 1)
    await wiring.model.teardown()
}

// The half that must not be paused. Preparing anecdotes needs the feed and the
// sidecar, and neither of them is the clock — an outage is exactly when the
// queue should be filling, so that recovery has something to show immediately
// rather than paying for a model load on the first delivery back.
@Test @MainActor func maintenanceStillRunsWhileTheDeviceIsOffline() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })

    schedule.tick()

    // Read once the beat is over, not the moment the log first looks right: an
    // ungated tick passes through exactly `[maintain, maintain]` on its way
    // from its restock to its run, so a wait on that shape alone is satisfied
    // by the tick this test says must not happen.
    #expect(await waitUntil { schedule.parked == 1 })
    // The tick's own restock, on top of the launch's, and nothing else.
    #expect(host.calls == ["maintain:stub", "maintain:stub"])
    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// The press is the consent. A "Run now" while the clock is down runs, fails,
// and says why — silence would read as the button being broken, which is
// precisely the defect this branch already shipped once.
//
// Over the shipped host, because half the rule is that the REASON lands where
// the user is looking, and a spy that answers `.delivered` has no reason to
// give.
@Test @MainActor func aManualRunStillRunsWhileTheDeviceIsOffline() async {
    let schedule = Metronome()
    let wiring = modelOverRealHost(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)), sleep: schedule.sleep
    )

    wiring.model.start()
    #expect(await waitUntil { isOffline(wiring.model) })

    wiring.model.runNow("stub")

    #expect(await waitUntil { wiring.model.lastResults["stub"]?.hasPrefix("failed:") == true })
    await wiring.model.teardown()
}

// `.unknown` is not offline. Before the first poll answers, nothing has been
// established about the clock — and a gate that read the two-state mirror the
// glyph uses would find `isDeviceOnline` false for both and run nothing at all
// at launch.
//
// The clock here has been asked and has not answered YET: the poll is parked
// inside the transport, which is what holds the state at `.unknown` for as long
// as this test needs rather than for however long a race allows.
@Test @MainActor func anUnknownDeviceStateDoesNotPauseTheSchedule() async {
    let host = SpyHost()
    let schedule = Metronome()
    let gate = Gate()
    let subject = testModel(host: host, transport: GatedTransport(gate: gate), sleep: schedule.sleep)

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(subject.monitor.state == .unknown)

    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    #expect(subject.monitor.state == .unknown)
    // Released so the poll is not left parked on a continuation nothing will
    // ever resume.
    gate.open()
    await subject.teardown()
}

// What the panel says while the pause holds. A time named for a run that will
// not happen is the failure `NextRun.held` exists to avoid — the user plans
// around it — and this gate is the second thing to supply its own words.
@Test @MainActor func aPausedScheduleSaysTheClockIsUnreachableRatherThanNamingAnHour() async {
    let schedule = Metronome()
    let subject = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)), sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { schedule.parked == 1 })
    // The beat is kept here rather than needed: the poll refreshes the hold on
    // its own twenty seconds now, and `anOutageReachesThePanelOnThePollRather
    // ThanAtTheNextBeat` is the test that says so. What this one still pins is
    // the words a beat writes when it finds the clock down.
    schedule.tick()

    #expect(await waitUntil { subject.nextRun["stub"] == .held(AppModel.deviceUnreachable) })
    let line = NextRunLine.text(for: subject.nextRun["stub"]) ?? ""
    #expect(line.isEmpty == false)
    #expect(line.contains(where: \.isNumber) == false)
    await subject.teardown()
}

// The label the schedule wrote is a snapshot taken up to an interval ago, and
// the gate behind it moves on its own clock. Before the poll refreshed it, the
// panel went on naming an hour right through an outage the app had already
// observed — half an hour of it on the shipped cadence, with the status line one
// row up saying Disconnected at the same time.
//
// The schedule is deliberately NOT ticked after the outage: the only thing that
// can write the label here is the reachability poll.
@Test @MainActor func anOutageReachesThePanelOnThePollRatherThanAtTheNextBeat() async {
    let schedule = Metronome()
    let poll = Metronome()
    let clock = SwitchableTransport()
    let subject = testModel(transport: clock, sleep: schedule.sleep, pollSleep: poll.sleep)

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { poll.parked == 1 })
    guard case .due = subject.nextRun["stub"] else {
        Issue.record("expected a due time, got \(String(describing: subject.nextRun["stub"]))")
        return
    }

    clock.nowFails()
    poll.tick()

    #expect(await waitUntil { subject.nextRun["stub"] == .held(AppModel.deviceUnreachable) })
    await subject.teardown()
}

// And back again. A clock that answers again puts a TIME on the panel without
// waiting for a beat, or the row stays stuck on "clock unreachable" for the rest
// of the interval while the app is perfectly happy.
@Test @MainActor func aClockThatComesBackPutsATimeOnThePanelWithoutWaitingForABeat() async {
    let schedule = Metronome()
    let poll = Metronome()
    let clock = SwitchableTransport(answering: false)
    let subject = testModel(transport: clock, sleep: schedule.sleep, pollSleep: poll.sleep)

    subject.start()
    #expect(await waitUntil { subject.nextRun["stub"] == .held(AppModel.deviceUnreachable) })
    #expect(await waitUntil { poll.parked == 1 })

    clock.nowAnswers()
    poll.tick()

    #expect(await waitUntil { isDue(subject.nextRun["stub"]) })
    await subject.teardown()
}

/// Whether the panel is naming a time rather than a reason.
@MainActor
func isDue(_ next: NextRun?) -> Bool {
    if case .due = next { return true }
    return false
}

// MARK: - What a replay says for itself

// The half of the discarded result that stays discarded. A replay is not a run:
// the connector's own line goes on describing what the SCHEDULE last did, and a
// failure heard from the History must not be written over it — nor counted,
// which `aReplayStillDoesNotMoveTheFailureCounter` owns.
//
// The failing case, deliberately. A replay that works and a replay that is
// dropped on the floor both leave the run line empty, so a successful one
// cannot tell the rule from its absence.
//
// The run at the end is the control: the same model, the same line, and it does
// get written — so the emptiness above is a refusal rather than a line nothing
// here can reach.
@Test @MainActor func aReplayOutcomeNeverReachesTheRunLine() async throws {
    let host = SpyHost(deliverResult: .failed("the clock is not answering"))
    let here = try playableAnecdote(id: "here", text: "still here")
    let subject = testModel(
        host: host,
        anecdotes: StubAnecdotes(history: [PlayedAnecdote(anecdote: here, playedAt: Date())])
    )

    subject.replay(here)

    #expect(await waitUntil { subject.replayResult != nil })
    #expect(subject.replayResult?.contains("the clock is not answering") == true)
    #expect(subject.lastResults["stub"] == nil)

    subject.runNow("stub")

    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
    // And the replay's own answer is still the replay's, not overwritten by the
    // run that followed it.
    #expect(subject.replayResult?.contains("the clock is not answering") == true)
}

// The other half, read off the shipped host's own count. `deliver` has no
// connector id to record against and that is the point: the backoff describes
// how the FEED is behaving, and hearing this morning's anecdote again is not
// evidence about anekdot.ru in either direction — least of all when it fails
// because the clock is unplugged.
//
// The manual run at the end is the control: the same wiring, the same
// unreachable clock, and it DOES move the count.
@Test @MainActor func aReplayStillDoesNotMoveTheFailureCounter() async throws {
    let here = try playableAnecdote(id: "here", text: "still here")
    let wiring = modelOverRealHost(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        anecdotes: StubAnecdotes(history: [PlayedAnecdote(anecdote: here, playedAt: Date())])
    )

    wiring.model.replay(here)

    #expect(await waitUntil { wiring.model.replayResult?.hasPrefix("failed:") == true })
    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 0)

    wiring.model.runNow("stub")

    #expect(await waitUntil { wiring.model.lastResults["stub"]?.hasPrefix("failed:") == true })
    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 1)
    await wiring.model.teardown()
}

// Opening the surface is asking what has played, not asking again about the
// last thing that was pressed. An answer kept across the open would be read as
// having just happened — and since the window close now takes the surface with
// it, "just opened" is the only state it is ever entered in.
@Test @MainActor func openingTheHistoryClearsTheLastReplaysAnswer() async throws {
    let here = try playableAnecdote(id: "here", text: "still here")
    let subject = testModel(
        host: SpyHost(deliverResult: .failed("the clock is not answering")),
        anecdotes: StubAnecdotes(history: [PlayedAnecdote(anecdote: here, playedAt: Date())])
    )
    subject.openHistory()
    subject.replay(here)
    #expect(await waitUntil { subject.replayResult != nil })

    subject.openHistory()

    #expect(subject.replayResult == nil)
}

// MARK: - Giving the clock back

// `OVERLAY` is GLOBAL device state: not scoped to an app, written to flash, and
// changeable by hand from the clock's own web interface. Borrowing it is the
// only way to draw weather on this firmware, so the two rules below are what
// keeps borrowing from being taking — the app removes what it created, and a
// setting is as much of a trace as a file on the flash.

@Test @MainActor func thePriorOverlayIsRestoredWhenTheConnectorIsDisabled() async {
    // Snow, not clear: what has to come back is what the device actually had,
    // which the user may well have set by hand.
    let transport = SkyAndClockTransport(overlayOnDevice: "snow")
    let weather = weatherConnector(over: transport)
    let wiring = modelOverRealHost(connector: weather, transport: transport)

    wiring.model.runNow("weather")
    #expect(await waitUntil { wiring.model.lastResults["weather"] == "delivered" })
    #expect(transport.overlayWrites == ["rain"])

    wiring.model.setEnabled(false, for: weather)

    #expect(await waitUntil { transport.overlayWrites == ["rain", "snow"] })
    await wiring.model.teardown()
}

@Test @MainActor func thePriorOverlayIsRestoredOnQuit() async {
    let transport = SkyAndClockTransport(overlayOnDevice: "snow")
    let weather = weatherConnector(over: transport)
    let wiring = modelOverRealHost(connector: weather, transport: transport)

    wiring.model.runNow("weather")
    #expect(await waitUntil { wiring.model.lastResults["weather"] == "delivered" })
    #expect(transport.overlayWrites == ["rain"])

    await wiring.model.teardown()

    #expect(transport.overlayWrites == ["rain", "snow"])
}

// Switching a connector ON is not a restore. It was the OFF that gave the
// overlay back, and a restore on the way in would write the value that is
// already there — the needless flash cycle this whole record exists to avoid.
@Test @MainActor func switchingAConnectorOnGivesNothingBack() async {
    let transport = SkyAndClockTransport(overlayOnDevice: "snow")
    let weather = weatherConnector(over: transport)
    let wiring = modelOverRealHost(connector: weather, transport: transport)

    wiring.model.runNow("weather")
    #expect(await waitUntil { wiring.model.lastResults["weather"] == "delivered" })

    wiring.model.setEnabled(true, for: weather)

    #expect(await waitUntil({ transport.overlayWrites.count > 1 }, limit: 0.1) == false)
    #expect(transport.overlayWrites == ["rain"])
    await wiring.model.teardown()
}

// A quit that arrives before anything was borrowed writes nothing at all. The
// record is what decides, not the fact that a quit happened — a blanket
// "set it to clear on the way out" would change a device this app never touched.
@Test @MainActor func aQuitThatBorrowedNothingWritesNothingBack() async {
    let transport = SkyAndClockTransport()
    let wiring = modelOverRealHost(
        connector: weatherConnector(over: transport), transport: transport
    )

    await wiring.model.teardown()

    #expect(transport.overlayWrites.isEmpty)
}

// The quit path against a clock that has stopped answering — which is the
// ordinary way a quit goes wrong, since the usual reason somebody quits is that
// they are unplugging things.
//
// Two claims, and the second is the one worth having. The quit finishes: the
// restore is the last thing teardown does and a refused write must not leave it
// hanging. And what could not be given back is still owed — the record survives
// the refusal, so a restore that reaches the clock later still knows what to put
// back, rather than having quietly dropped the only copy of the user's own
// overlay.
@Test @MainActor func aQuitAgainstAnUnreachableClockStillFinishesAndStillOwesTheOverlay() async {
    let transport = SkyAndClockTransport(overlayOnDevice: "snow")
    let weather = weatherConnector(over: transport)
    let wiring = modelOverRealHost(connector: weather, transport: transport)

    wiring.model.runNow("weather")
    #expect(await waitUntil { wiring.model.lastResults["weather"] == "delivered" })
    #expect(transport.currentOverlay == "rain")

    transport.stopAnswering()
    await wiring.model.teardown()

    // Reaching this line is the first claim. The restore was ATTEMPTED — it
    // reached the clock and was refused — which is what stops this test
    // passing on a teardown that never tried. And the clock still holds this
    // app.s overlay, because a refused write changed nothing on it.
    #expect(transport.overlayWrites == ["rain", "snow"])
    #expect(transport.currentOverlay == "rain")

    transport.startAnswering()
    await wiring.host.restoreDeviceState(borrowedBy: nil)

    #expect(transport.currentOverlay == "snow")
}
