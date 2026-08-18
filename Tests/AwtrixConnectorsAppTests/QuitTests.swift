import AppKit
import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// MARK: - The budget

// The number is not chosen here. The wait exists for the held banner's dismiss,
// which is sent on a task cancellation cannot break, so it lasts exactly as long
// as one request may last. A budget shorter than the transport's own timeout
// kills the app mid-release and leaves the banner on the clock.
@Test func theQuitBudgetIsTheTransportsOwnRequestTimeout() {
    #expect(QuitBudget.transportTimeout == URLSessionTransport.defaultTimeout)
    #expect(QuitBudget().seconds == QuitBudget.transportTimeout)
}

@Test func quitWaitsForTeardownBeforeItReplies() async {
    let torndown = Signal()

    let settled = await QuitBudget(seconds: 5).settle {
        try? await Task.sleep(for: .milliseconds(20))
        torndown.send()
    }

    #expect(settled)
    // The point of the wait: the answer comes back only once teardown is done.
    #expect(torndown.isSent)
}

// The other half. Two things in the delivery chain can outlast a cancellation
// for good — the sidecar's read loop blocks a thread that never learns about
// one — so a wait with no cap is a quit that hangs.
@Test func aTeardownThatOutlivesTheBudgetStillLetsTheAppQuit() async {
    let settled = await QuitBudget(seconds: 0.01).settle {
        try? await Task.sleep(for: .milliseconds(400))
    }

    #expect(settled == false)
}

// The budget is spent waiting, not sleeping: a teardown that finishes at once
// must not hold the quit for the whole fifteen seconds.
@Test func aTeardownThatFinishesAtOnceDoesNotWaitOutTheBudget() async {
    let started = Date()

    let settled = await QuitBudget(seconds: 30).settle {}

    #expect(settled)
    #expect(Date().timeIntervalSince(started) < 1)
}

// A clock that cannot tell the time must expire the budget rather than remove
// it. Swallowed, nothing is ever left to offer an answer and the wait this type
// exists to bound becomes unbounded — a quit that hangs for ever.
@Test func aClockThatFailsExpiresTheBudgetRatherThanRemovingIt() async {
    struct BrokenClock: Error {}
    let budget = QuitBudget(seconds: 0.01, sleep: { _ in throw BrokenClock() })

    let settled = await budget.settle {
        try? await Task.sleep(for: .milliseconds(400))
    }

    #expect(settled == false)
}

// MARK: - The line macOS actually calls

// `applicationShouldTerminate` is the only thing connecting any of the above to
// macOS. Returning a bare `.terminateNow` ends the process without taking the
// budget, without tearing down and without waiting for the banner release — and
// every test below this line still passes, because none of them go through it.
//
// Two claims, because the return value alone does not carry the second: macOS
// is asked to wait, AND the budget is actually taken. The budget's own clock is
// the witness for the second — `settle` starts its expiry racer by sleeping the
// budget, so a duration appearing on that clock is proof the wait began.
@Test @MainActor func quittingAsksMacOSToWaitAndTakesTheBudget() async {
    let gate = Gate()
    let schedule = Metronome()
    let subject = testModel(host: SpyHost(parkInRun: gate), sleep: schedule.sleep)
    subject.start()
    await waitUntil { schedule.parked == 1 }
    schedule.tick()
    await waitUntil { gate.enteredCount == 1 }

    let budgetClock = Metronome()
    let delegate = AppDelegate(
        model: subject,
        budget: QuitBudget(seconds: 600, sleep: budgetClock.sleep),
        discovery: inertDiscovery()
    )

    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
    #expect(await waitUntil { budgetClock.durations == [600] })

    // The gate stays shut on purpose. Opening it would let the reply reach the
    // real `NSApplication`, and `reply(toApplicationShouldTerminate:)` outside a
    // termination sequence is not something to do to the process running the
    // tests. What this test owns is the question, not the answer — the answer is
    // `beginTermination`'s, three tests up.
    //
    // No `teardown()` either, for the same reason: the one this test started is
    // already inside the budget's wait, and calling it again would be waiting on
    // the gate this test is deliberately leaving shut. The loops it leaves are
    // parked on the double's clock, not spinning.
}

// MARK: - The delegate

@Test @MainActor func quittingAsksForMoreTimeAndRepliesOnlyOnceTeardownHasSettled() async {
    let gate = Gate()
    let metronome = Metronome()
    let subject = testModel(host: SpyHost(parkInRun: gate), sleep: metronome.sleep)
    subject.start()
    await waitUntil { metronome.parked > 0 }
    metronome.tick()
    await waitUntil { gate.enteredCount == 1 }

    let delegate = AppDelegate(model: subject, budget: QuitBudget(seconds: 5), discovery: inertDiscovery())
    let replies = Replies()
    let answer = delegate.beginTermination { replies.record($0) }

    // `.terminateNow` here would end the process while the banner it put on the
    // clock is still being taken down.
    #expect(answer == .terminateLater)
    #expect(await waitUntil({ replies.recorded.isEmpty == false }, limit: 0.05) == false)

    gate.open()
    #expect(await waitUntil { replies.recorded.isEmpty == false })
    #expect(replies.recorded == [true])
}

// A budget that expires still answers yes. Answering no would cancel the quit
// and leave the app running with its schedules already cancelled and its poll
// stopped — a worse state than the one the user asked for.
@Test @MainActor func aQuitThatRunsOutOfBudgetStillAnswersYes() async {
    let gate = Gate()
    let metronome = Metronome()
    let subject = testModel(host: SpyHost(parkInRun: gate), sleep: metronome.sleep)
    subject.start()
    await waitUntil { metronome.parked > 0 }
    metronome.tick()
    await waitUntil { gate.enteredCount == 1 }

    let delegate = AppDelegate(model: subject, budget: QuitBudget(seconds: 0.01), discovery: inertDiscovery())
    let replies = Replies()
    _ = delegate.beginTermination { replies.record($0) }

    #expect(await waitUntil { replies.recorded == [true] })
    gate.open()
}

/// What the delegate answered, in order.
final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool] = []

    var recorded: [Bool] { lock.withLock { answers } }
    func record(_ answer: Bool) { lock.withLock { answers.append(answer) } }
}
