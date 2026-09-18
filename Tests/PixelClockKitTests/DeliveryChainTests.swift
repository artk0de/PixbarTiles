import Foundation
import Testing
@testable import PixelClockKit

// The chain on its own, with no clock behind it. Everything here was already
// true of `ConnectorHost`, and is pinned there too, through a device. These say
// it of the chain alone, because the TC002's session will hold one without the
// AWTRIX session's tests around it.

/// Parks work handed to the chain until the test lets it go.
///
/// A continuation rather than a sleep, and deliberately not cancellation-aware:
/// a sleep would throw on cancellation and answer the question these tests ask
/// before the chain gets to.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var entered = 0

    var enteredCount: Int { lock.withLock { entered } }

    func open() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            let all = waiting
            waiting = []
            return all
        }
        held.forEach { $0.resume() }
    }

    func enter() async {
        lock.withLock { entered += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// How many pieces of work have started, and the most that were ever inside
/// the chain at once.
private final class Occupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var peak = 0
    private var started = 0

    var highest: Int { lock.withLock { peak } }
    var startedCount: Int { lock.withLock { started } }

    func enter() {
        lock.withLock {
            inside += 1
            started += 1
            peak = max(peak, inside)
        }
    }

    func leave() { lock.withLock { inside -= 1 } }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(waitBudget(nil))
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

// A run and a replay take their turns in one queue. `dismissNotification` is
// global to an AWTRIX clock, so two deliveries inside at once end with one
// taking down the other's banner mid-speech.
@Test func theChainRunsOnePieceOfWorkAtATime() async throws {
    let chain = DeliveryChain()
    let latch = Latch()
    let occupancy = Occupancy()
    let work: @Sendable () async -> RunResult = {
        occupancy.enter()
        await latch.enter()
        occupancy.leave()
        return .delivered
    }

    let first = Task { await chain.run(for: "a", work) }
    try await waitUntil { latch.enteredCount == 1 }
    let second = Task { await chain.deliver(work) }
    // Long enough for an unserialised second piece to have started.
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(occupancy.startedCount == 1)

    latch.open()
    #expect(await first.value == .delivered)
    #expect(await second.value == .delivered)
    #expect(occupancy.highest == 1)
}

// Cancellation cannot break the wait for a predecessor, so the check on the far
// side of that wait is what keeps a cancelled delivery off the clock.
@Test func workCancelledWhileQueuedNeverStarts() async throws {
    let chain = DeliveryChain()
    let latch = Latch()
    let occupancy = Occupancy()

    let first = Task { await chain.run(for: "a") { await latch.enter(); return .delivered } }
    try await waitUntil { latch.enteredCount == 1 }
    let queued = Task { await chain.run(for: "a") { occupancy.enter(); return .delivered } }
    try await Task.sleep(nanoseconds: 20_000_000)
    queued.cancel()
    latch.open()

    #expect(await queued.value == .cancelled)
    #expect(await first.value == .delivered)
    #expect(occupancy.startedCount == 0)
}

// The work runs in an unstructured task, which inherits nothing from its
// caller. Without cancellation forwarded by hand, a caller that gives up gets
// neither the work stopped nor itself back.
@Test func aCallerThatGivesUpCancelsTheWorkItWasWaitingFor() async throws {
    let chain = DeliveryChain()
    let occupancy = Occupancy()
    let run = Task {
        await chain.run(for: "a") {
            occupancy.enter()
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return .cancelled }
            return .delivered
        }
    }
    try await waitUntil { occupancy.startedCount == 1 }

    let cancelledAt = ContinuousClock.now
    run.cancel()

    #expect(await run.value == .cancelled)
    #expect(ContinuousClock.now - cancelledAt < .seconds(1))
}

// The backoff describes the feed. A replay says nothing about it, and neither
// does a delivery somebody called off.
@Test func aRunsOutcomeIsCountedAndADeliverysIsNot() async {
    let chain = DeliveryChain()
    _ = await chain.run(for: "a") { .failed("down") }
    _ = await chain.run(for: "a") { .failed("down") }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 2)

    _ = await chain.deliver { .failed("refused") }
    _ = await chain.deliver { .delivered }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 2)

    _ = await chain.run(for: "a") { .cancelled }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 2)

    _ = await chain.run(for: "a") { .delivered }
    #expect(await chain.consecutiveFailures(connectorId: "a") == 0)
    #expect(await chain.consecutiveFailures(connectorId: "b") == 0)
}

// A failing connector is retried sooner than its cadence and never later.
@Test func theBackoffIsClippedToTheCadence() async {
    let chain = DeliveryChain(retryPolicy: RetryPolicy(base: 30, cap: 1800))
    #expect(await chain.nextDelay(connectorId: "a", interval: 600) == 600)

    _ = await chain.run(for: "a") { .failed("down") }

    #expect(await chain.nextDelay(connectorId: "a", interval: 600) == 30)
    #expect(await chain.nextDelay(connectorId: "a", interval: 10) == 10)
}

// One reading of a thrown error for both halves of a run. Only the two ways a
// cancellation arrives read as one; a timeout is an outage.
@Test func onlyACancellationIsReadAsOne() {
    #expect(DeliveryChain.classify(CancellationError()) == .cancelled)
    #expect(DeliveryChain.classify(URLError(.cancelled)) == .cancelled)
    guard case .failed = DeliveryChain.classify(URLError(.timedOut)) else {
        Issue.record("a timeout is an outage, not a cancellation")
        return
    }
    guard case .failed = DeliveryChain.classify(AwtrixError.invalidHost("nowhere")) else {
        Issue.record("a device fault is a failure")
        return
    }
}
