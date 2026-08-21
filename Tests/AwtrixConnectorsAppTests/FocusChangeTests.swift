import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// A Focus turning on or off, and the clock catching up with it.
//
// Nothing tells this app that the user switched Focus — there is no callback to
// register for — so the reachability poll is the minute hand it has. Without
// this, a connector whose visibility depends on the Focus waits out its own
// cadence: up to five minutes to appear when work starts, and a whole lifetime
// to leave when Sleep does, which is a lit number on a clock beside a bed.

private func gated(_ status: StubFocusStatus) -> [FocusGatedConnector] {
    [FocusGatedConnector(id: "claude") { ClaudeFocusAudience.shows(status) }]
}

@Test @MainActor func switchingIntoAFocusThatShowsItDeliversWithoutWaitingForTheBeat() async {
    let status = StubFocusStatus(
        access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")
    )
    let host = SpyHost()
    let subject = testModel(host: host, focus: focusGate(status), focusGated: gated(status))

    // One turn to learn where the Focus started, so the next has something to
    // notice a change against.
    subject.reactToAFocusChange()
    status.nowIn(.mode("com.apple.focus.work"))
    subject.reactToAFocusChange()

    #expect(await waitUntil { host.calls.contains("run:claude") })
    #expect(!host.calls.contains("restore:claude"))
}

@Test @MainActor func switchingIntoAFocusThatHidesItTakesItOffTheClockAtOnce() async {
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let host = SpyHost()
    let subject = testModel(host: host, focus: focusGate(status), focusGated: gated(status))

    subject.reactToAFocusChange()
    status.nowIn(.mode("com.apple.sleep.sleep-mode"))
    subject.reactToAFocusChange()

    // Retracted rather than merely left unrefreshed. Nothing on the clock takes
    // an app off for going stale until its lifetime expires, so "stop feeding
    // it" is fifteen minutes of a number that should already be gone.
    #expect(await waitUntil { host.calls.contains("restore:claude") })
    #expect(!host.calls.contains("run:claude"))
}

// A Focus that has not changed is not a reason to do anything.
//
// The poll turns once a minute for as long as the app is running. Re-pushing an
// unchanged app sixty times an hour would be sixty writes to the clock for a
// number that moves every five minutes, and re-retracting one that is already
// gone would be sixty more.
@Test @MainActor func aFocusThatStaysTheSameIsLeftAlone() async {
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let host = SpyHost()
    let subject = testModel(host: host, focus: focusGate(status), focusGated: gated(status))

    for _ in 0..<4 { subject.reactToAFocusChange() }

    #expect(!host.calls.contains("run:claude"))
    #expect(!host.calls.contains("restore:claude"))
}

// The first reading is not a switch.
//
// `deliverWhatTheLaunchOwes` already hands the loop what a launch owes it, on
// the same poll this runs in. Counting the first reading as a transition would
// push the same app twice on the same turn — or, worse, retract the app the
// launch had just delivered.
@Test @MainActor func theFirstReadingIsNotTreatedAsASwitch() async {
    let asleep = StubFocusStatus(
        access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")
    )
    let host = SpyHost()
    let subject = testModel(host: host, focus: focusGate(asleep), focusGated: gated(asleep))

    subject.reactToAFocusChange()

    #expect(!host.calls.contains("restore:claude"))
    #expect(!host.calls.contains("run:claude"))
}
