import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// This app speaks out loud on a thirty-minute schedule, and nothing stopped it
// telling a joke at three in the morning. The gate is macOS's own Focus state
// rather than a window the app invents — with one trap that decides the whole
// design: an UNAUTHORIZED centre answers `isFocused == false`, which is exactly
// what a genuinely idle Mac answers. Trusting that reading is an app that
// believes no Focus is ever on, silently and by construction.

// MARK: - The window itself

@Test func aQuietWindowCoversTheHoursBetweenItsEnds() {
    let window = QuietWindow(startHour: 9, endHour: 17)

    #expect(window.contains(atHour(8)) == false)
    #expect(window.contains(atHour(9)))
    #expect(window.contains(atHour(16)))
    // Exclusive at the end, so 17:00 is the hour it starts speaking again.
    #expect(window.contains(atHour(17)) == false)
}

// The shipped default wraps midnight, so this is not an edge case the user has
// to go looking for — it is the case.
@Test func aQuietWindowThatWrapsMidnightCoversBothSidesOfIt() {
    let night = QuietWindow(startHour: 23, endHour: 8)

    #expect(night.contains(atHour(23)))
    #expect(night.contains(atHour(3)))
    #expect(night.contains(atHour(7)))
    #expect(night.contains(atHour(8)) == false)
    #expect(night.contains(atHour(12)) == false)
    #expect(night.contains(atHour(22)) == false)
}

// Two pickers can be dragged onto the same hour, and that has to mean
// something. Zero length is zero quiet — the alternative reading, a window that
// swallows the whole day, is a menu bar toy that has gone permanently mute
// because somebody scrolled one wheel too far.
@Test func aQuietWindowOfZeroLengthSilencesNothing() {
    let window = QuietWindow(startHour: 3, endHour: 3)

    #expect(window.contains(atHour(3)) == false)
    #expect(window.contains(atHour(4)) == false)
    #expect(window.contains(atHour(2)) == false)
}

@Test func aWindowSaysItselfAsTwoHoursOnAClock() {
    #expect(QuietWindow(startHour: 23, endHour: 8).label == "23:00–08:00")
    #expect(QuietWindow(startHour: 0, endHour: 7).label == "00:00–07:00")
}

// Midnight is a real choice, and `integer(forKey:)` answers 0 for a key nobody
// ever wrote — so a window starting at 00:00 read back through that would be
// indistinguishable from no window at all, and the second half of the pair
// would silently become the default's.
@Test func aWindowStartingAtMidnightIsNotMistakenForAnUnsetOne() throws {
    let name = "quiet-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    #expect(QuietWindow.stored(in: defaults) == .default)

    QuietWindow(startHour: 0, endHour: 6).save(to: defaults)

    #expect(QuietWindow.stored(in: defaults) == QuietWindow(startHour: 0, endHour: 6))
}

// MARK: - Which rule is in force

// The trap, stated as directly as it can be. An unauthorized centre and an idle
// authorized one give the SAME answer to `isFocused`, and only one of them is
// evidence.
@Test func anUnauthorizedCenterIsNotTreatedAsPermissionToSpeak() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let threeInTheMorning: @Sendable () -> Date = { atHour(3) }
    // Both centres say the same thing about Focus, and they say it truthfully:
    // no Focus is on. What differs is whether this app is allowed to believe it.
    let unauthorized = FocusGate(
        status: StubFocusStatus(access: .notDetermined, isFocused: false), now: threeInTheMorning
    )
    let authorized = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: false), now: threeInTheMorning
    )

    #expect(unauthorized.silence(quietHours: night) == FocusGate.duringQuietHours)
    // Identical answer from the centre, and now the identical silence. This
    // line read `== nil` while the authorized branch dropped the window — which
    // was the app speaking at three in the morning on the first build macOS
    // ever answered, and is what task 49 took away.
    #expect(authorized.silence(quietHours: night) == FocusGate.duringQuietHours)

    // The discrimination the line above used to carry, at the hour where it is
    // still expressible. At noon the window has nothing to say, so the only
    // thing left that can answer is whether the centre may be believed — and
    // both of these report a Focus while only one of them is evidence.
    let unauthorizedDuringAFocus = FocusGate(
        status: StubFocusStatus(access: .notDetermined, isFocused: true), now: { atHour(12) }
    )
    let authorizedDuringAFocus = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: true), now: { atHour(12) }
    )

    #expect(unauthorizedDuringAFocus.silence(quietHours: night) == nil)
    #expect(authorizedDuringAFocus.silence(quietHours: night) == FocusGate.duringFocus)
}

// A refusal is an answer, and it is not permission. `.denied` reaching the
// authorized branch would put the app back on a reading it has been told it may
// not have.
@Test func theQuietWindowAppliesWhenFocusAuthorizationWasDenied() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let refused = StubFocusStatus(access: .denied, isFocused: false)
    let atThree = FocusGate(status: refused, now: { atHour(3) })
    let atNoon = FocusGate(status: refused, now: { atHour(12) })

    #expect(atThree.rule(quietHours: night) == .quietHours(night))
    #expect(atThree.silence(quietHours: night) == FocusGate.duringQuietHours)
    // And the window is a window, not a mute: outside it the app speaks even
    // though the centre is still refused.
    #expect(atNoon.silence(quietHours: night) == nil)
}

// Restricted is the fourth answer — managed devices, parental controls — and it
// is no more evidence than a refusal.
@Test func aRestrictedCenterFallsBackToTheWindowToo() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(access: .restricted, isFocused: true), now: { atHour(12) }
    )

    #expect(gate.rule(quietHours: night) == .quietHours(night))
    // Focused, and it makes no difference: the reading is not this app's to use.
    #expect(gate.silence(quietHours: night) == nil)
}

// While the app IS allowed to ask, the system's own state is the better answer
// — and outside the window it is the only gate with anything to say, so it
// decides alone. Read at noon and not at three, which is where this used to
// stand: the window is consulted now whatever the centre says, and the same
// centre at three is `theQuietWindowHoldsWhileTheCenterIsAuthorizedAndNothingIs
// On` giving the opposite answer.
@Test func anAuthorizedCenterDecidesAloneOutsideTheWindow() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: false), now: { atHour(12) }
    )

    #expect(gate.rule(quietHours: night) == .focus)
    #expect(gate.silence(quietHours: night) == nil)
}

@Test func anAuthorizedCenterReportingAFocusSaysSoInItsOwnWords() {
    let gate = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: true), now: { atHour(12) }
    )

    #expect(gate.silence(quietHours: .default) == FocusGate.duringFocus)
    #expect(FocusGate.duringFocus != FocusGate.duringQuietHours)
}

// MARK: - Both gates, not one of them

// The defect, and it shipped. The exclusive choice this replaces was written
// while `INFocusStatusCenter` had never once answered `.authorized` on this
// machine, so the branch that dropped the window could not be reached and read
// as harmless. A self-signed identity revived the centre — measured `status=3,
// authorized` — and the user's own 23:00–08:00 stopped applying on the build
// they are running, at the one hour nobody is awake to notice.
@Test func theQuietWindowHoldsWhileTheCenterIsAuthorizedAndNothingIsOn() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: false, activeMode: .noFocus),
        now: { atHour(3) }
    )

    #expect(gate.silence(quietHours: night) == FocusGate.duringQuietHours)
}

// A Focus this app speaks through does not reopen the night. Работа at three in
// the morning is somebody working late, and the hours they set aside are about
// the hour rather than about what they are doing in it.
@Test func aFocusThisAppSpeaksThroughDoesNotReopenTheQuietWindow() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode("com.apple.focus.work")
        ),
        now: { atHour(3) }
    )

    #expect(gate.silence(quietHours: night) == FocusGate.duringQuietHours)
}

// The same Работа one gate over, and the window is still a window rather than a
// mute. This is the rule the user asked for and the one this change leaves
// exactly where it was.
@Test func aFocusThisAppSpeaksThroughStillSpeaksOutsideTheWindow() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode("com.apple.focus.work")
        ),
        now: { atHour(12) }
    )

    #expect(gate.silence(quietHours: night) == nil)
}

// Both gates want silence, and the WINDOW is the reason given. Not a coin toss:
// `AppModel.duringTheQuietWindow` compares this very string to decide whether
// the nightly refresh may SPEND, so a 3 a.m. Sleep reported as the Focus would
// let it load a 1.8 GB model and spin the fans inside the hours somebody set
// aside for not being disturbed.
@Test func insideTheWindowTheWindowIsTheReasonEvenWhenAFocusAgrees() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode("com.apple.sleep.sleep-mode")
        ),
        now: { atHour(3) }
    )

    #expect(gate.silence(quietHours: night) == FocusGate.duringQuietHours)
}

// The shipping app's own state, and it is not a corner case. Signed, the centre
// answers; Full Disk Access is still refused, so the mode is `.cannotTell` and
// the boolean is all there is. The window stands beside it either way — the two
// permissions are granted separately and this app holds one of them.
@Test func anUnreadableModeLeavesTheWindowInForce() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: false, activeMode: .cannotTell),
        now: { atHour(3) }
    )

    #expect(gate.silence(quietHours: night) == FocusGate.duringQuietHours)
}

// And the fallback keeps the direction it was given: told nothing about the
// mode, every Focus silences. Read at noon, so the answer is the boolean's and
// not the hour's — the window would say the same thing for the wrong reason.
@Test func anUnreadableModeStillLetsEveryFocusSilence() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let gate = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: true, activeMode: .cannotTell),
        now: { atHour(12) }
    )

    #expect(gate.silence(quietHours: night) == FocusGate.duringFocus)
}

// MARK: - The schedule

// Two models alike in everything — same connector, same spy, same beat, same
// clock answering — except that macOS reports a Focus on one of them. The
// unfocused one delivers on the very beat the focused one declines, so "no run"
// cannot be a schedule that was never built, a connector switched off, or a
// tick that never arrived.
@Test @MainActor func anActiveFocusSilencesTheSchedule() async {
    let focusedHost = SpyHost()
    let focusedSchedule = Metronome()
    let focused = testModel(
        host: focusedHost,
        sleep: focusedSchedule.sleep,
        focus: focusGate(StubFocusStatus(access: .authorized, isFocused: true))
    )
    let freeHost = SpyHost()
    let freeSchedule = Metronome()
    let free = testModel(
        host: freeHost,
        sleep: freeSchedule.sleep,
        focus: focusGate(StubFocusStatus(access: .authorized, isFocused: false))
    )

    focused.start()
    free.start()
    // The launch's own restock, waited out on both, so everything after it
    // belongs to the beat.
    #expect(await waitUntil { focusedHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { freeHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { focusedSchedule.parked == 1 })
    #expect(await waitUntil { freeSchedule.parked == 1 })

    focusedSchedule.tick()
    freeSchedule.tick()

    #expect(await waitUntil { freeHost.calls.contains("run:stub") })
    // Waited on the BEAT BEING OVER — asleep again on the next interval —
    // rather than on a call count. A count of two is reached half-way through
    // an ungated tick as well, between its restock and its run.
    #expect(await waitUntil { focusedSchedule.parked == 1 })
    #expect(focusedHost.calls == ["maintain:stub", "maintain:stub"])
    #expect(focusedHost.calls.contains("run:stub") == false)
    await focused.teardown()
    await free.teardown()
}

// Nothing about the silence is sticky. The timer keeps its beat, so the first
// beat after the Focus ends delivers — there is no state to clear and nothing
// to wait for.
@Test @MainActor func theScheduleResumesWhenFocusEnds() async {
    let host = SpyHost()
    let schedule = Metronome()
    let centre = StubFocusStatus(access: .authorized, isFocused: true)
    let subject = testModel(host: host, sleep: schedule.sleep, focus: focusGate(centre))

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    // The beat is over — asleep again — before the log is read, or the absence
    // of a delivery is only the absence of one YET.
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.contains("run:stub") == false)

    centre.nowFocused(false)
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    await subject.teardown()
}

// The whole gate, through the schedule, at the hour it exists for. Both models
// are UNAUTHORIZED and both centres answer `isFocused == false`; what separates
// them is the window, and the one whose window has not come round delivers on
// the same beat.
@Test @MainActor func theQuietWindowSilencesTheScheduleWhileTheCenterIsUnauthorized() async {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let sleepingHost = SpyHost()
    let sleepingSchedule = Metronome()
    let asleep = testModel(
        host: sleepingHost,
        sleep: sleepingSchedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(3) }),
        quietHours: night
    )
    let awakeHost = SpyHost()
    let awakeSchedule = Metronome()
    let awake = testModel(
        host: awakeHost,
        sleep: awakeSchedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(12) }),
        quietHours: night
    )

    asleep.start()
    awake.start()
    #expect(await waitUntil { sleepingHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { awakeHost.calls == ["maintain:stub"] })
    #expect(await waitUntil { sleepingSchedule.parked == 1 })
    #expect(await waitUntil { awakeSchedule.parked == 1 })

    sleepingSchedule.tick()
    awakeSchedule.tick()

    #expect(await waitUntil { awakeHost.calls.contains("run:stub") })
    #expect(await waitUntil { sleepingSchedule.parked == 1 })
    // The launch's restock and nothing else: a beat inside the quiet window
    // spends nothing at all, which is `theNightlyRefreshDoesNotRunInsideThe
    // UsersQuietHours`. A Focus is the other way round and still is —
    // `maintenanceStillRunsDuringFocus`.
    #expect(sleepingHost.calls == ["maintain:stub"])
    #expect(sleepingHost.calls.contains("run:stub") == false)
    await asleep.teardown()
    await awake.teardown()
}

// The half that must not be silenced. Preparing anecdotes makes no sound: it
// needs the feed and the sidecar, and neither of them is in the room. A Focus
// is exactly when the queue should be filling, so that the user coming back to
// their desk is not paying for a model load on the first delivery.
@Test @MainActor func maintenanceStillRunsDuringFocus() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focus: focusGate(StubFocusStatus(access: .authorized, isFocused: true))
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

// The one thing a beat inside the quiet window must not do is spend. The daily
// refresh triggers on a calendar day boundary, and midnight is inside every
// plausible quiet window — so the first beat after 00:00 loaded a 1.8 GB model
// and synthesized a batch, with fans, on the machine of somebody who had just
// told the app these hours were not for making noise in.
//
// Read once the beat is over rather than on a call count: an ungated tick
// passes through exactly `[maintain, maintain]` on its way from its restock to
// its run.
@Test @MainActor func theNightlyRefreshDoesNotRunInsideTheUsersQuietHours() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(0) }),
        quietHours: QuietWindow(startHour: 23, endHour: 8)
    )

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })

    schedule.tick()

    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls == ["maintain:stub"])
    await subject.teardown()
}

// And it is deferred rather than skipped: the first beat outside the window
// finds the same nothing prepared today and does the same work, while its owner
// is awake. Two models alike in everything but the hour.
@Test @MainActor func theNightlyRefreshRunsOnTheFirstBeatOutsideTheQuietHours() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(9) }),
        quietHours: QuietWindow(startHour: 23, endHour: 8)
    )

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })

    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:stub") })
    #expect(host.calls.filter { $0 == "maintain:stub" }.count > 1)
    await subject.teardown()
}

// An outage is a different fact and keeps its own rule: the feed and the sidecar
// are fine, and a paused schedule outside the quiet window is exactly when the
// queue should be filling so recovery has something to show immediately.
@Test @MainActor func aPausedBeatOutsideTheQuietHoursStillRestocks() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        sleep: schedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(12) }),
        quietHours: QuietWindow(startHour: 23, endHour: 8)
    )

    subject.start()
    #expect(await waitUntil { isOffline(subject) })
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })

    schedule.tick()

    #expect(await waitUntil { host.calls == ["maintain:stub", "maintain:stub"] })
    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// A meeting is not the night either. A busy microphone says the user is at the
// machine and will turn back to it, which is when the queue should be filling —
// the same argument `maintenanceStillRunsDuringFocus` makes one gate over.
@Test @MainActor func aBeatHeldByAMicrophoneStillRestocks() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(12) }),
        quietHours: QuietWindow(startHour: 23, endHour: 8),
        microphone: MicrophoneGate(inputs: StubAudioInputs(duringAMeeting))
    )

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })
    #expect(await waitUntil { schedule.parked == 1 })

    schedule.tick()

    #expect(await waitUntil { host.calls == ["maintain:stub", "maintain:stub"] })
    #expect(host.calls.contains("run:stub") == false)
    await subject.teardown()
}

// The press is the consent. A "Run now" during a Focus runs and says how it
// went — silence would read as the button being broken, which is precisely the
// defect this branch already shipped once.
@Test @MainActor func aManualRunIsNeverSilenced() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focus: focusGate(StubFocusStatus(access: .authorized, isFocused: true))
    )

    subject.start()
    #expect(await waitUntil { host.calls == ["maintain:stub"] })

    subject.runNow("stub")

    #expect(await waitUntil { subject.lastResults["stub"] == "delivered" })
    #expect(host.calls.contains("run:stub"))
    await subject.teardown()
}

// A Focus is neither a failure nor a success. The backoff describes how the
// FEED is behaving, and the user's attention says nothing about anekdot.ru: a
// count that grew through an afternoon of meetings would have a healthy
// connector retrying every thirty seconds afterwards, and a count cleared by
// one would have a genuinely broken feed hammered as if it were fine.
//
// Read off the shipped host's own count, with both directions in one test and a
// control at each end.
@Test @MainActor func aFocusPauseDoesNotAdvanceOrResetTheFailureCounter() async {
    let schedule = Metronome()
    let centre = StubFocusStatus(access: .authorized, isFocused: false)
    let wiring = modelOverRealHost(
        connector: BrokenConnector(),
        transport: StubTransport(body: onlineStats),
        focus: focusGate(centre),
        sleep: schedule.sleep
    )

    wiring.model.start()
    #expect(await waitUntil { wiring.model.isDeviceOnline })
    // Earned with no Focus on, so the failure is the feed's.
    wiring.model.runNow("stub")
    #expect(await waitUntil { wiring.model.lastResults["stub"]?.hasPrefix("failed:") == true })
    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 1)

    centre.nowFocused(true)
    #expect(await waitUntil { schedule.parked == 1 })
    for _ in 0..<3 {
        schedule.tick()
        #expect(await waitUntil { schedule.parked == 1 })
    }

    // Not advanced by three silenced beats against a feed that always throws,
    // and not reset by them either.
    #expect(await wiring.host.consecutiveFailures(connectorId: "stub") == 1)

    // The control at the far end: the same wiring, the same broken feed, and a
    // press that IS allowed through does move the count — so the number above
    // is the schedule declining to run rather than a counter nothing here can
    // reach.
    wiring.model.runNow("stub")
    #expect(await waitForFailures(of: "stub", on: wiring.host, toReach: 2) == 2)
    await wiring.model.teardown()
}

// What the panel says while the silence holds. A time named for a run that will
// not happen is the failure `NextRun.held` exists to avoid, and this gate is the
// third thing to supply its own words.
@Test @MainActor func aSilencedScheduleSaysWhichRuleSilencedItRatherThanNamingAnHour() async {
    let schedule = Metronome()
    let focused = testModel(
        sleep: schedule.sleep,
        focus: focusGate(StubFocusStatus(access: .authorized, isFocused: true))
    )
    let quiet = Metronome()
    let atNight = testModel(
        sleep: quiet.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(3) }),
        quietHours: QuietWindow(startHour: 23, endHour: 8)
    )

    focused.start()
    atNight.start()

    #expect(await waitUntil { focused.nextRun["stub"] == .held(FocusGate.duringFocus) })
    #expect(await waitUntil { atNight.nextRun["stub"] == .held(FocusGate.duringQuietHours) })
    let line = NextRunLine.text(for: focused.nextRun["stub"]) ?? ""
    #expect(line.isEmpty == false)
    #expect(line.contains(where: \.isNumber) == false)
    await focused.teardown()
    await atNight.teardown()
}

// Asked once, at launch, and never from a gate check. Measured on this machine,
// `INFocusStatusCenter.requestAuthorization` never calls its handler back and
// aborts the process outright when TCC cannot attribute a usage description to
// it — so the answer is read off `access` on every turn, and the ask itself is
// a one-shot with nothing waiting on it.
@Test @MainActor func macOSIsAskedForFocusAccessOnceAtLaunch() async {
    let centre = StubFocusStatus(access: .notDetermined)
    let schedule = Metronome()
    let subject = testModel(sleep: schedule.sleep, focus: focusGate(centre))

    #expect(centre.accessRequests == 0)

    subject.start()

    #expect(await waitUntil { centre.accessRequests == 1 })
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { schedule.parked == 1 })
    // Beats do not re-ask. A prompt raised every half hour is a prompt the user
    // learns to dismiss.
    #expect(centre.accessRequests == 1)
    await subject.teardown()
}

// MARK: - The window the user sets

@Test @MainActor func theQuietHoursTheUserPicksAreSavedAndReadBack() throws {
    let name = "quiet-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let subject = testModel(defaults: defaults)

    subject.setQuietHours(QuietWindow(startHour: 1, endHour: 9))

    #expect(subject.quietHours == QuietWindow(startHour: 1, endHour: 9))
    #expect(QuietWindow.stored(in: defaults) == QuietWindow(startHour: 1, endHour: 9))
}

// The value the pickers write is the value the gate reads. Set through the
// model and asked of the schedule, so a setter that published without reaching
// the gate — two copies of one window — is caught here rather than by a user
// wondering why 23:00 does nothing.
@Test @MainActor func theWindowTheUserSetsIsTheOneTheScheduleObeys() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        host: host,
        sleep: schedule.sleep,
        focus: FocusGate(status: StubFocusStatus(access: .denied), now: { atHour(3) }),
        quietHours: QuietWindow(startHour: 9, endHour: 17)
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    // Three in the morning is outside 09:00–17:00, so the schedule speaks.
    #expect(await waitUntil { host.calls.contains("run:stub") })

    subject.setQuietHours(QuietWindow(startHour: 23, endHour: 8))

    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()
    #expect(await waitUntil { subject.nextRun["stub"] == .held(FocusGate.duringQuietHours) })
    let after = host.calls.filter { $0 == "run:stub" }.count
    #expect(await waitUntil { schedule.parked == 1 })
    #expect(host.calls.filter { $0 == "run:stub" }.count == after)
    await subject.teardown()
}

// MARK: - Which rule the settings say is in force

@Test func theRuleLineNamesTheSystemWhenTheSystemIsAnswering() {
    let line = FocusRuleLine.text(for: .focus)

    #expect(line.contains("Focus"))
    // No hours in it: naming a window while the system is deciding would tell
    // the user their pickers are doing something they are not.
    #expect(line.contains(where: \.isNumber) == false)
}

@Test func theRuleLineNamesTheWindowWhenTheSystemWillNotAnswer() {
    let window = QuietWindow(startHour: 23, endHour: 8)

    let line = FocusRuleLine.text(for: .quietHours(window))

    #expect(line.contains(window.label))
    #expect(line != FocusRuleLine.text(for: .focus))
}
