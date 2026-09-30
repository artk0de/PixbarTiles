import Testing
@testable import PixbarTilesApp

/// The one registry of the model's own tasks: every piece of work it starts is
/// held here, so a teardown can cancel all of it and wait for what was in
/// flight — a banner's release included.
@MainActor
@Suite struct TaskBagTests {
    @Test func finishedWorkLeavesTheBag() async {
        let bag = TaskBag()
        let done = Latch()
        bag.run { await done.open() }
        await done.wait()
        await Task.yield()
        #expect(bag.count == 0)
    }

    @Test func replacingANameCancelsTheWorkUnderIt() async {
        let bag = TaskBag()
        let first = Latch()
        bag.replace("history") {
            await withTaskCancellationHandler { try? await Task.sleep(for: .seconds(60)) } onCancel: {}
            await first.open(cancelled: Task.isCancelled)
        }
        bag.replace("history") {}
        await first.wait()
        #expect(first.wasCancelled)
    }

    @Test func aNamedJobRefusesASecondWhileTheFirstRuns() async {
        let bag = TaskBag()
        let release = Latch()
        #expect(bag.startIfIdle("icons") { await release.wait() })
        #expect(!bag.startIfIdle("icons") {})
        #expect(bag.isRunning("icons"))
        await release.open()
        while bag.isRunning("icons") { await Task.yield() }
        #expect(bag.startIfIdle("icons") {})
    }

    @Test func cancellingWaitsForAnUncancellableTail() async {
        let bag = TaskBag()
        let tail = Latch()
        bag.run {
            try? await Task.sleep(for: .seconds(60))    // cancelled
            await Task.yield()
            await tail.open()                           // still runs: a release goes out
        }
        let extra = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        await bag.cancelAndWait(also: [extra])
        #expect(tail.isOpen)
        #expect(extra.isCancelled)
        #expect(bag.count == 0)
    }
}

/// A one-shot gate a test can wait on.
@MainActor
final class Latch {
    private(set) var isOpen = false
    private(set) var wasCancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open(cancelled: Bool = false) {
        isOpen = true
        wasCancelled = cancelled
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
