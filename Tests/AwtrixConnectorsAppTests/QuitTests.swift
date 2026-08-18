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

// MARK: - The delegate

@Test @MainActor func quittingAsksForMoreTimeAndRepliesOnlyOnceTeardownHasSettled() async {
    let gate = Gate()
    let metronome = Metronome()
    let subject = testModel(host: SpyHost(parkInRun: gate), sleep: metronome.sleep)
    subject.start()
    await waitUntil { metronome.parked > 0 }
    metronome.tick()
    await waitUntil { gate.enteredCount == 1 }

    let delegate = AppDelegate(model: subject, budget: QuitBudget(seconds: 5))
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

    let delegate = AppDelegate(model: subject, budget: QuitBudget(seconds: 0.01))
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
