import AwtrixKit
import Foundation

/// How long quit may spend waiting for teardown, and the thing that enforces it.
///
/// A budget exists because cancelling work does not always release the caller
/// waiting on it. The delivery chain has two such places on purpose: the banner
/// release is sent on a task cancellation cannot break, and the sidecar's read
/// loop blocks a thread that never learns about cancellation at all. Waiting
/// forever on either would hang the quit; not waiting at all would kill the app
/// mid-release.
struct QuitBudget: Sendable {
    typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    /// The transport's own request timeout, and deliberately not a number
    /// chosen here.
    ///
    /// The wait exists for one collaborator: `ConnectorHost` sends the dismiss
    /// that takes a held banner off the clock on an uncancellable task, so it
    /// takes as long as that request takes and no longer. Anything shorter kills
    /// the app mid-release and leaves the banner up until somebody walks over
    /// and presses the middle button, which is the exact failure the
    /// uncancellable release exists to prevent. Anything longer only waits on a
    /// request that has already timed out.
    ///
    /// The audio is not a term in it: cancelling a playing clip was measured at
    /// 0.9-6.3 ms mid-clip, and about 270 ms on the first cancel in a process.
    static let transportTimeout: TimeInterval = URLSessionTransport.defaultTimeout

    let seconds: TimeInterval
    private let sleep: Sleeping

    init(
        seconds: TimeInterval = QuitBudget.transportTimeout,
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.seconds = seconds
        self.sleep = sleep
    }

    /// Runs `teardown` and stops waiting for it after the budget. Reports
    /// whether it finished in time.
    ///
    /// The teardown is left running when the budget expires rather than
    /// cancelled. It is already the product of a cancellation — what is still
    /// going is the release that must not be interrupted — and the process is
    /// about to end anyway, so cancelling it could only cut short the one thing
    /// this wait was protecting.
    func settle(_ teardown: @escaping @Sendable () async -> Void) async -> Bool {
        let first = FirstToFinish()
        _ = Task {
            await teardown()
            await first.offer(true)
        }
        let expiry = Task {
            do {
                try await sleep(seconds)
            } catch is CancellationError {
                // This task, cancelled by the line below — which only runs once
                // the answer is already in.
                return
            } catch {
                // Any other failure is a clock that cannot tell the time, and
                // the safe reading of that is an expired budget. Swallowed, it
                // would leave nothing to ever offer `false`, and the wait this
                // type exists to bound would be unbounded.
            }
            await first.offer(false)
        }

        let finished = await first.wait()
        expiry.cancel()
        return finished
    }
}

/// Whichever of two racers finished first, delivered once to a single waiter.
///
/// A task group would be the obvious shape and is the wrong one: it does not
/// return until every child has, so the losing child — the teardown this exists
/// to stop waiting for — would still be waited for.
private actor FirstToFinish {
    private var answer: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func offer(_ value: Bool) {
        guard answer == nil else { return }
        answer = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait() async -> Bool {
        if let answer { return answer }
        return await withCheckedContinuation { waiter = $0 }
    }
}
