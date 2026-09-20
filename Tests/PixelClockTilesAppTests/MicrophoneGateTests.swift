import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// Speech and the clock's jingle both land in the room the user is talking in.
// If a microphone is capturing the app WAITS — it does not skip. A joke
// deferred by twenty minutes is still a joke; one skipped is gone, and it was
// already paid for in synthesis.
//
// The trap the probe caught, which would otherwise have shipped as "the app
// never speaks and nobody knows why": on this machine the naive check — is any
// input capturing — answers true right now, with no meeting in progress,
// because `Universal Audio Thunderbolt` reports `capturing == true`
// permanently. Every fixture here keeps that device in the list.

// MARK: - Whose microphone counts

// The gate answers on its FIRST read, with no baseline of any kind. An earlier
// draft excluded devices already capturing at startup, to dodge the always-on
// interface; with an explicit watch set that heuristic is not merely
// unnecessary but wrong — a watched microphone already hot when the app
// launches means a meeting is already in progress, and the right answer is to
// hold.
// Through the MODEL as well as the gate, and that is the half that matters: a
// baseline is state, and state is something `AppModel` could grow just as
// easily as `MicrophoneGate` could. A gate-level assertion alone leaves a
// baseline kept one layer up completely unexamined.
@Test @MainActor func aWatchedDeviceCapturingAtLaunchIsAMeetingAlreadyInProgress() async {
    let system = StubAudioInputs(duringAMeeting)
    let gate = MicrophoneGate(inputs: system)

    // The very first question anybody asks it, and it already answers.
    #expect(system.enumerations == 0)
    #expect(gate.capturing(watching: MicrophoneGate.defaultWatchSet) == duringAMeeting[0])
    #expect(system.enumerations == 1)

    // And the schedule obeys it from its first beat. The control is a model
    // alike in everything except that the room is quiet, so "no run" cannot be
    // a schedule that was never built.
    let heldHost = SpyHost()
    let heldSchedule = Metronome()
    let held = testModel(
        host: heldHost,
        sleep: heldSchedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )
    let freeHost = SpyHost()
    let freeSchedule = Metronome()
    let free = testModel(
        host: freeHost,
        sleep: freeSchedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(afterTheMeeting))
    )

    held.start()
    free.start()
    #expect(await waitUntil { heldSchedule.parked == 1 })
    #expect(await waitUntil { freeSchedule.parked == 1 })
    heldSchedule.tick()
    freeSchedule.tick()

    #expect(await waitUntil { freeHost.calls.contains("run:stub") })
    #expect(await waitUntil { heldSchedule.parked == 1 })
    #expect(heldHost.calls.contains("run:stub") == false)
    await held.teardown()
    await free.teardown()
}

// The whole reason the set is explicit. The interface is capturing on every one
// of these reads, and no number of them turns it into a meeting.
@Test func anUnwatchedDeviceCapturingIsIgnoredHoweverLongItRuns() {
    let gate = MicrophoneGate(inputs: StubAudioInputs(afterTheMeeting))

    for _ in 0..<20 {
        #expect(gate.capturing(watching: MicrophoneGate.defaultWatchSet) == nil)
    }
    // And it is there to be ignored: a fixture with nothing capturing would
    // prove nothing about the filter at all.
    #expect(afterTheMeeting.contains { $0.isCapturing })
}

// A watched device that is absent is simply not capturing. Its absence is not
// an error, and — the half that matters — it must not disable the gate for the
// devices that ARE present.
@Test func aWatchedDeviceThatIsAbsentDoesNotDisableTheGate() {
    let gate = MicrophoneGate(inputs: StubAudioInputs())
    let withPhoneGone = MicrophoneGate(
        inputs: StubAudioInputs([Inputs.interface, Inputs.capturing(Inputs.builtIn)])
    )
    let quietWithPhoneGone = MicrophoneGate(
        inputs: StubAudioInputs([Inputs.interface, Inputs.builtIn])
    )
    // Watched, and not in either list below.
    #expect(MicrophoneGate.defaultWatchSet.contains { $0.name == "iPhone Microphone" })

    // The absent phone does not swallow the built-in microphone's answer.
    #expect(withPhoneGone.capturing(watching: MicrophoneGate.defaultWatchSet)?.name
        == "MacBook Pro Microphone")
    // Nor does it invent one: absent is not capturing.
    #expect(quietWithPhoneGone.capturing(watching: MicrophoneGate.defaultWatchSet) == nil)
    #expect(gate.capturing(watching: MicrophoneGate.defaultWatchSet) == nil)
}

// Names are user-visible and unstable — "iPhone Microphone" comes and goes with
// the phone, and measured on this machine "ROG CETRA TWS SN" already names two
// devices at once. So the fixture is a deliberate collision: the watched UID
// belongs to a device whose NAME is somebody else's, and the watched NAME
// belongs to a capturing device that is not watched.
@Test func theWatchSetIsMatchedByUidNotByName() {
    // Same UID as the real built-in microphone, wearing a different name.
    let renamed = AudioInput(
        uid: "BuiltInMicrophoneDevice", name: "Studio Mic", isCapturing: true
    )
    // A different device that happens to carry the name the entry was written
    // with, and is capturing.
    let impostor = AudioInput(
        uid: "some-other-device", name: "MacBook Pro Microphone", isCapturing: true
    )
    let watching = [
        WatchedMicrophone(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    ]
    let gate = MicrophoneGate(inputs: StubAudioInputs([Inputs.interface, impostor, renamed]))

    // The UID wins in both directions at once: the hold is the renamed device,
    // and it is NOT the one whose name matches.
    #expect(gate.capturing(watching: watching)?.uid == "BuiltInMicrophoneDevice")
    #expect(gate.capturing(watching: watching)?.name == "Studio Mic")
}

// The name is the fallback, and only for an entry whose UID resolves to nothing
// present — a shipped default that has never been edited, or a device back with
// a new UID. That is what makes the defaults work at all before the user has
// ticked anything.
@Test func anEntryWhoseUidIsNowhereFallsBackToTheName() {
    let phoneWithANewUid = AudioInput(
        uid: "A-BRAND-NEW-UID", name: "iPhone Microphone", isCapturing: true
    )
    let watching = [WatchedMicrophone(uid: "THE-OLD-UID", name: "iPhone Microphone")]
    let gate = MicrophoneGate(
        inputs: StubAudioInputs([Inputs.interface, Inputs.builtIn, phoneWithANewUid])
    )

    #expect(gate.capturing(watching: watching)?.uid == "A-BRAND-NEW-UID")
}

// MARK: - The set the user keeps

@Test func theWatchSetIsSavedAndReadBack() throws {
    let name = "mics-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    #expect(WatchedMicrophone.stored(in: defaults) == MicrophoneGate.defaultWatchSet)

    WatchedMicrophone.save([WatchedMicrophone(uid: "u", name: "n")], to: defaults)

    #expect(WatchedMicrophone.stored(in: defaults) == [WatchedMicrophone(uid: "u", name: "n")])
}

// Unticking every box is an instruction, not an absence. Folded back to the
// default it would silently re-tick the two the user had just cleared, and the
// app would go on waiting for microphones they told it to ignore.
@Test func anEmptyWatchSetIsADecisionRatherThanAnUnsetOne() throws {
    let name = "mics-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    WatchedMicrophone.save([], to: defaults)

    #expect(WatchedMicrophone.stored(in: defaults) == [])
}

// Ticking a box writes the UID this app has just seen, which is what upgrades a
// shipped default from a name to an identity.
@Test @MainActor func tickingADeviceRecordsItsUidRatherThanOnlyItsName() throws {
    let name = "mics-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let subject = testModel(
        defaults: defaults,
        microphone: MicrophoneGate(inputs: StubAudioInputs()),
        watching: []
    )

    subject.setWatched(true, for: Inputs.builtIn)

    #expect(subject.watchedMicrophones
        == [WatchedMicrophone(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")])
    #expect(WatchedMicrophone.stored(in: defaults) == subject.watchedMicrophones)
}

// The box the shipped defaults tick carries no UID, so removing it by entry
// equality would leave a box that cannot be unticked — the user turns the
// waiting off and the app goes on waiting.
@Test @MainActor func aShippedDefaultCanBeUntickedEvenThoughItCarriesNoUid() {
    let subject = testModel(microphone: MicrophoneGate(inputs: StubAudioInputs()))
    #expect(subject.watchedMicrophones.contains { $0.uid == nil && $0.name == Inputs.builtIn.name })

    subject.setWatched(false, for: Inputs.builtIn)

    #expect(subject.watchedMicrophones.contains { $0.name == Inputs.builtIn.name } == false)
    #expect(subject.microphoneListing.first { $0.input == Inputs.builtIn }?.isWatched == false)
}

// The list is every input the system reports, watched ones marked — not just
// the watched ones. A gate the user cannot inspect is a gate they will
// eventually fight, and the interface that reports itself busy for ever only
// makes sense next to the ones that do not.
@Test @MainActor func everyInputIsListedWithTheWatchedOnesMarked() {
    let subject = testModel(microphone: MicrophoneGate(inputs: StubAudioInputs(
        [Inputs.builtIn, Inputs.phone, Inputs.interface, Inputs.virtual]
    )))

    let listing = subject.microphoneListing

    #expect(listing.count == 4)
    #expect(listing.filter(\.isWatched).map(\.input.name)
        == ["MacBook Pro Microphone", "iPhone Microphone"])
    #expect(listing.first { $0.input == Inputs.interface }?.isWatched == false)
}

// MARK: - Deferral, not suppression

// Two models alike in everything — same connector, same spy, same beat — except
// that a watched microphone is capturing on one of them. The quiet one delivers
// on the very beat the busy one declines.
//
// And it is HELD, not dropped: the schedule metronome is never ticked again
// after the meeting, so the run that arrives at the end can only have come from
// the release. That is the discriminator this whole feature turns on — a test
// that ticked the schedule again could not tell "held then released" from "ran
// late".
@Test @MainActor func aScheduledRunDuringAMeetingIsHeldNotDropped() async {
    let busyHost = SpyHost()
    let busySchedule = Metronome()
    let busyMic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let busy = testModel(
        host: busyHost,
        sleep: busySchedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: busyMic.sleep
    )
    let freeHost = SpyHost()
    let freeSchedule = Metronome()
    let free = testModel(
        host: freeHost,
        sleep: freeSchedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(afterTheMeeting))
    )

    busy.start()
    free.start()
    #expect(await waitUntil { busyHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { freeHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { busySchedule.parked == 1 })
    #expect(await waitUntil { freeSchedule.parked == 1 })
    #expect(await waitUntil { busyMic.parked == 1 })

    busySchedule.tick()
    freeSchedule.tick()

    #expect(await waitUntil { freeHost.calls.contains("run:stub") })
    #expect(await waitUntil { busySchedule.parked == 1 })
    #expect(busyHost.calls.contains("run:stub") == false)

    // The meeting ends. The SCHEDULE is not touched from here on.
    system.nowReports(afterTheMeeting)
    busyMic.tick()

    #expect(await waitUntil { busyHost.calls.contains("run:stub") })
    await busy.teardown()
    await free.teardown()
}

// What releases it is capture stopping, not the passage of time. The watch loop
// turns three times with the microphone still hot and nothing comes out of it;
// the turn after the microphone goes quiet delivers.
@Test @MainActor func theHeldRunFiresWhenCaptureStops() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { mic.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    for _ in 0..<3 {
        mic.tick()
        #expect(await waitUntil { mic.parked == 1 })
    }
    // Three turns of the watch loop, and the run is still held: it is the
    // microphone that releases it, not the loop.
    #expect(host.calls.contains("run:stub") == false)

    system.nowReports(afterTheMeeting)
    mic.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    await subject.teardown()
}

// What the panel blames, once the microphone has stopped. The reason was written
// once per turn of the SCHEDULE — half an hour on the shipped cadence — so the
// row went on naming a microphone that had gone quiet long before, and it did so
// AFTER the run it held had already played. The watch loop that releases the run
// is the one that clears the words.
//
// The schedule is deliberately not ticked after the meeting, so nothing but the
// watch loop can have written either the run or the label.
@Test @MainActor func theHeldReasonLeavesThePanelWhenTheMicrophoneGoesQuiet() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { mic.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(subject.nextRun["stub"] == .held(MicrophoneGate.inUse(Inputs.builtIn.name)))

    system.nowReports(afterTheMeeting)
    mic.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    #expect(await waitUntil { isDue(subject.nextRun["stub"]) })
    await subject.teardown()
}

// The other direction, and the one that makes the refresh a fix rather than a
// race: a microphone that starts capturing between beats is named on the panel
// before the beat it will hold. Without it the row promised an hour it had
// already decided not to honour.
@Test @MainActor func aMicrophoneThatStartsCapturingIsNamedBeforeTheBeatItHolds() async {
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(afterTheMeeting)
    let subject = testModel(
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { mic.parked == 1 })
    #expect(isDue(subject.nextRun["stub"]))

    system.nowReports(duringAMeeting)
    mic.tick()

    #expect(
        await waitUntil {
            subject.nextRun["stub"] == .held(MicrophoneGate.inUse(Inputs.builtIn.name))
        }
    )
    await subject.teardown()
}

// A two-hour meeting must not queue four anecdotes and fire them in a burst the
// moment it ends. Four beats go by held; exactly one run comes out.
@Test @MainActor func atMostOneRunIsHeldAcrossALongMeeting() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { mic.parked == 1 })
    for _ in 0..<4 {
        schedule.tick()
        #expect(await waitUntil { schedule.parked == 1 })
    }
    #expect(host.calls.contains("run:stub") == false)

    system.nowReports(afterTheMeeting)
    // Several turns of the watch loop, so a second held run would have every
    // chance to come out.
    for _ in 0..<4 {
        mic.tick()
        #expect(await waitUntil { mic.parked == 1 })
    }

    #expect(await waitUntil { host.calls.contains("run:stub") })
    #expect(host.calls.filter { $0 == "run:stub" }.count == 1)
    await subject.teardown()
}

// A hold is neither a failure nor a success. Read off the shipped host's own
// count, against a feed that throws every time it is asked — so any run that
// DID happen would move it — with the control at the far end: a press that is
// allowed through moves the same counter through the same wiring.
@Test @MainActor func aHeldRunIsNotCountedAsAFailure() async {
    let schedule = Metronome()
    let wiring = modelOverRealHost(
        connector: BrokenConnector(),
        transport: StubTransport(body: onlineStats),
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting)),
        sleep: schedule.sleep
    )

    wiring.model.start()
    #expect(await waitUntil { wiring.model.isDeviceOnline })
    #expect(await waitUntil { schedule.parked == 1 })
    for _ in 0..<3 {
        schedule.tick()
        #expect(await waitUntil { schedule.parked == 1 })
    }

    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 0)

    wiring.model.runNow("stub")

    #expect(await waitForFailures(of: "stub", on: wiring.host, toReach: 1) == 1)
    await wiring.model.teardown()
}

// The press is the consent, and the user can see the microphone indicator in
// their own menu bar. Holding it would read as a broken button, which is
// precisely the defect this branch already shipped once.
@Test @MainActor func aManualRunIsNeverHeld() async {
    let host = SpyHost()
    let subject = testModel(
        host: host, microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })

    subject.runNow("stub")

    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
    #expect(host.calls.contains("run:stub"))
    await subject.teardown()
}

// Preparation makes no sound. A meeting is exactly when the queue should be
// filling, so the run released at the end has something to hand out rather than
// paying for a model load on the play path.
@Test @MainActor func maintenanceIsNeverHeld() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })

    schedule.tick()

    // Read once the beat is over, not the moment the log first looks right: an
    // ungated tick passes through exactly `[maintain, maintain]` on its way
    // from its restock to its run.
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls == ["maintain:stub", "maintain:stub"])
    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// "Waiting" on its own is not diagnosable and silence is worse. The device that
// caused it is the one the user has to go and look at — and it is the WATCHED
// one, not merely the first thing in the list that happens to be capturing.
// Here the always-on interface is capturing and comes first; the answer names
// the built-in microphone.
@Test @MainActor func thePanelNamesTheDeviceThatCausedTheWait() async {
    let schedule = Metronome()
    let subject = testModel(
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(
            [Inputs.interface, Inputs.capturing(Inputs.builtIn), Inputs.phone]
        ))
    )

    subject.start()

    #expect(await waitUntil {
        subject.nextRun["stub"] == .held(MicrophoneGate.inUse("MacBook Pro Microphone"))
    })
    let line = NextRunLine.text(for: subject.nextRun["stub"]) ?? ""
    #expect(line.contains("MacBook Pro Microphone"))
    #expect(line.contains("Universal Audio") == false)
    // No hour named for a run that is not going to happen at one.
    #expect(line.contains(where: \.isNumber) == false)
    await subject.teardown()
}

// The release is a gate, not a firing squad: a run held through a meeting that
// ends inside a Focus stays held rather than speaking into the Focus. Nothing
// here is sticky — the same watch loop lets it go the moment both are clear.
@Test @MainActor func aRunHeldIntoAFocusStaysHeldUntilTheFocusEndsToo() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let centre = StubFocusStatus(access: .authorized, isFocused: false)
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focusStatus: (centre),
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { mic.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })

    centre.nowFocused(true)
    system.nowReports(afterTheMeeting)
    mic.tick()
    #expect(await waitUntil { mic.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    centre.nowFocused(false)
    mic.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    await subject.teardown()
}

// MARK: - What is owed, and what is merely missed

// Only a microphone hold is a WAIT. An outage of the clock is a SKIP: nothing is
// spent, nothing is owed, and the next beat delivers. Queueing one would fire an
// anecdote the instant the clock answered, and a burst of them on every device
// recovery.
//
// The schedule is never ticked again after the outage, so a run appearing here
// could only have come from the release loop.
@Test @MainActor func aBeatMissedWhileTheClockWasDownIsNotOwedAfterwards() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let poll = Metronome()
    let clock = SwitchableTransport(answering: false)
    let subject = testModel(
        host: host,
        transport: clock,
        sleep: schedule.sleep,
        pollSleep: poll.sleep,
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    clock.nowAnswers()
    poll.tick()
    #expect(await waitUntil { subject.isDeviceOnline })
    for _ in 0..<4 {
        mic.tick()
        #expect(await waitUntil { mic.parked == 1 })
    }

    // Four turns of the loop that releases held runs, with nothing holding
    // anything. Nothing was owed, so nothing comes out.
    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// The same for a quiet rule. Held beats through a nine-hour night would arrive
// as an anecdote at exactly 08:00 every morning — which is the alarm clock
// nobody asked this app to be.
@Test @MainActor func aBeatMissedDuringQuietHoursIsNotOwedWhenTheyEnd() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let centre = StubFocusStatus(access: .authorized, isFocused: true)
    let subject = testModel(
        host: host, sleep: schedule.sleep, focusStatus: (centre), micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    centre.nowFocused(false)
    for _ in 0..<4 {
        mic.tick()
        #expect(await waitUntil { mic.parked == 1 })
    }

    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// And the control at the far end, so the two above are a refusal rather than a
// release loop nothing can reach: the identical shape with a MICROPHONE holding
// the beat does deliver.
@Test @MainActor func aBeatMissedForAMicrophoneIsTheOneThatIsOwed() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    system.nowReports(afterTheMeeting)
    mic.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    await subject.teardown()
}

// Releasing into a clock that is not answering is worse than not releasing at
// all: `produce()` pops an anecdote and RETIRES it before the banner goes out,
// so the user permanently loses something they never heard and the failure
// counter advances for a device outage. That is the exact cost this hold exists
// to remove, through the one path it did not cover — a meeting that ends during
// an outage.
//
// The schedule is not ticked after the hold, so the run at the end is the
// release rather than a later beat.
@Test @MainActor func aRunHeldIntoAnOutageStaysHeldUntilTheClockAnswers() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let poll = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let clock = SwitchableTransport()
    let subject = testModel(
        host: host,
        transport: clock,
        sleep: schedule.sleep,
        pollSleep: poll.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { subject.isDeviceOnline })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })

    // The meeting ends, but the clock has gone down in the meantime.
    clock.nowFails()
    poll.tick()
    #expect(await waitUntil { isOffline(subject) })
    system.nowReports(afterTheMeeting)
    for _ in 0..<3 {
        mic.tick()
        #expect(await waitUntil { mic.parked == 1 })
    }
    #expect(host.calls.contains("run:stub") == false)

    clock.nowAnswers()
    poll.tick()
    #expect(await waitUntil { subject.isDeviceOnline })
    mic.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    await subject.teardown()
}

// MARK: - A connector that makes no sound

// The quiet rules exist to stop the app SPEAKING. Task 26 then added a
// connector that speaks nothing, draws into the device's own loop, and is
// enabled by default — and it inherited all three gates without anyone
// re-asking the question.
//
// On shipped defaults that is not marginal. `INFocusStatusCenter` never grants
// authorization on this machine, so the quiet window is the shipping rule: nine
// hours a night in which the clock's temperature froze at whatever it read
// before 23:00.
@Test @MainActor func aConnectorThatMakesNoSoundKeepsDrawingThroughAFocus() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [silentConnector],
        host: host,
        sleep: schedule.sleep,
        focusStatus: (StubFocusStatus(access: .authorized, isFocused: true))
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:silent") })
    await subject.teardown()
}

@Test @MainActor func aConnectorThatMakesNoSoundKeepsDrawingWhileAMicrophoneIsCapturing() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [silentConnector],
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:silent") })
    await subject.teardown()
}

// And the row says a time rather than blaming a microphone, which on a weather
// line is a non-sequitur the reader cannot act on.
@Test @MainActor func aSilentConnectorsRowNeverBlamesTheRoom() async {
    let schedule = Metronome()
    let subject = testModel(
        connectors: [silentConnector],
        sleep: schedule.sleep,
        focusStatus: (StubFocusStatus(access: .authorized, isFocused: true)),
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()

    #expect(await waitUntil { isDue(subject.nextRun["silent"]) })
    await subject.teardown()
}

// The offline pause is a different question and still applies: a clock that is
// not answering cannot receive a drawing any more than it can receive a banner.
@Test @MainActor func aConnectorThatMakesNoSoundStillPausesWhileTheClockIsDown() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [silentConnector],
        host: host,
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        sleep: schedule.sleep
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })

    #expect(host.calls.contains("run:silent") == false)
    #expect(subject.nextRun["silent"] == .held(AppModel.deviceUnreachable))
    await subject.teardown()
}

// A silent connector owes nothing either, and the case that decides it is the
// only one where the two gates overlap: the clock is down AND a microphone is
// capturing. The clock is what holds this connector; the microphone has nothing
// to do with it, so the beat is a SKIP and must not be queued against the
// meeting ending.
//
// Both are cleared before the release loop turns, and the schedule is never
// ticked again — so a run appearing here could only be a beat that was owed.
@Test @MainActor func aSilentConnectorsBeatIsNeverOwedToAMeeting() async {
    let host = SpyHost()
    let schedule = Metronome()
    let mic = Metronome()
    let poll = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let clock = SwitchableTransport(answering: false)
    let subject = testModel(
        connectors: [silentConnector],
        host: host,
        transport: clock,
        sleep: schedule.sleep,
        pollSleep: poll.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:silent") == false)

    clock.nowAnswers()
    poll.tick()
    #expect(await waitUntil { subject.isDeviceOnline })
    system.nowReports(afterTheMeeting)
    for _ in 0..<4 {
        mic.tick()
        #expect(await waitUntil { mic.parked == 1 })
    }

    #expect(host.calls.contains("run:silent") == false)
    await subject.teardown()
}

// Two connectors, one audible and one not, under the same Focus. The gate is a
// property of what is being scheduled, not of the app — and this is the shape
// the shipped app actually runs.
@Test @MainActor func aFocusSilencesTheSpeakingConnectorAndLeavesTheSilentOneRunning() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [StubConnector(), silentConnector],
        host: host,
        sleep: schedule.sleep,
        focusStatus: (StubFocusStatus(access: .authorized, isFocused: true))
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 2 })
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:silent") })
    #expect(host.calls.contains("run:stub") == false)
    #expect(subject.nextRun["stub"] == .held(FocusGate.duringFocus))
    #expect(isDue(subject.nextRun["silent"]))
    await subject.teardown()
}

// MARK: - When two of them hold at once

// The order is what the user is told, and until now nothing in the suite ever
// put two gates in force at the same time — so reversing the whole precedence
// left 653 tests green.
//
// The clock first, because an unreachable device is what the panel's own status
// line one row up is already about.
@Test @MainActor func anUnreachableClockOutranksAMicrophoneOnThePanel() async {
    let schedule = Metronome()
    let subject = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["stub"] == .held(AppModel.deviceUnreachable) })
    await subject.teardown()
}

@Test @MainActor func anUnreachableClockOutranksAQuietRuleOnThePanel() async {
    let schedule = Metronome()
    let subject = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        sleep: schedule.sleep,
        focusStatus: (StubFocusStatus(access: .authorized, isFocused: true))
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["stub"] == .held(AppModel.deviceUnreachable) })
    await subject.teardown()
}

// And the quiet rules before the microphone, because they are about the room
// rather than about a device the user can look at.
@Test @MainActor func aQuietRuleOutranksAMicrophoneOnThePanel() async {
    let schedule = Metronome()
    let subject = testModel(
        sleep: schedule.sleep,
        focusStatus: (StubFocusStatus(access: .authorized, isFocused: true)),
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["stub"] == .held(FocusGate.duringFocus) })
    await subject.teardown()
}

// A beat that lands WHILE a release is in flight must not have its hold
// swallowed by the release finishing. The meeting resumes, a scheduled run is
// held against it, and the release that was already running finishes on top —
// emptying the set after the runs rather than before would take the new hold
// with it, and that anecdote is gone with nothing to say it ever existed.
//
// Found by mutation: moving `heldRuns.removeAll()` below the loop survived the
// whole suite. The watch loop awaits each release, so there is no re-entry to
// defend against — this is the case that actually distinguishes the two.
@Test @MainActor func aHoldRecordedDuringAReleaseIsNotSwallowedByIt() async {
    let release = Gate()
    let host = SpyHost(parkInRun: release)
    let schedule = Metronome()
    let mic = Metronome()
    let system = StubAudioInputs(duringAMeeting)
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        microphone: MicrophoneGate(inputs: system),
        micSleep: mic.sleep
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(await waitUntil { mic.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })

    // The meeting ends and the release starts — and parks inside `runOnce`,
    // which is what gives the next beat somewhere to land.
    system.nowReports(afterTheMeeting)
    mic.tick()
    #expect(await waitUntil { host.calls.contains("run:stub") })

    // The meeting starts again while that run is still going, and a beat lands
    // on it.
    system.nowReports(duringAMeeting)
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })

    // Now the first release completes, on top of a set that already holds the
    // second.
    release.open()
    #expect(await waitUntil { mic.parked == 1 })

    system.nowReports(afterTheMeeting)
    mic.tick()

    #expect(await waitUntil { host.calls.filter { $0 == "run:stub" }.count == 2 })
    await subject.teardown()
}

// Teardown can only wait for a task it holds, and a released run puts the same
// held banner on the clock as any other. A quit that returned before it settled
// would kill the process during the release and leave the banner up.
@Test @MainActor func teardownStopsTheMicrophoneWatch() async {
    let mic = Metronome()
    let system = StubAudioInputs(afterTheMeeting)
    let subject = testModel(microphone: MicrophoneGate(inputs: system), micSleep: mic.sleep)

    subject.start()
    #expect(await waitUntil { mic.parked == 1 })

    await subject.teardown()

    #expect(mic.parked == 0)
    let asked = system.enumerations
    mic.tick()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(system.enumerations == asked)
}
