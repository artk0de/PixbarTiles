import Foundation

/// How one delivery went.
public enum RunResult: Sendable, Equatable {
    case delivered
    /// The user switched this connector off.
    case skipped
    /// Called off. Not a failure — nobody is waiting for the result any more,
    /// and a feed outage is a different thing entirely. Anything already put on
    /// the clock was taken back down first.
    case cancelled
    case failed(String)
}

/// One clock's deliveries, one at a time, and how the last runs went.
///
/// The part of the AWTRIX session that is not about any one firmware: the queue
/// that keeps two deliveries off a clock at once, the failure count a backoff
/// is read from, and the one reading of a thrown error that both halves of a
/// run share. A session owns one, and sessions do not share one — a clock that
/// has stopped answering holds up only its own deliveries.
///
/// It never sees a device, a connector or a setting. What it runs is a closure
/// the session hands it, and what it records is keyed by the id the session
/// names.
public actor DeliveryChain {
    private let retryPolicy: RetryPolicy

    /// The last delivery to have claimed a place. Deliveries run one at a time
    /// by waiting on it — see `queued(_:)` for how. Runs and replays share it,
    /// which is the whole point: two chains would be no serialisation at all.
    private var tail: Task<Void, Never>?

    /// Deliveries failed in a row, per connector. An id that is not in here has
    /// none. In memory only: a relaunch is a fresh start, and a connector that
    /// is still down earns its backoff again within a couple of intervals.
    private var failureCounts: [String: Int] = [:]

    public init(retryPolicy: RetryPolicy = RetryPolicy()) {
        self.retryPolicy = retryPolicy
    }

    /// How many runs of this connector have failed in a row.
    public func consecutiveFailures(connectorId: String) -> Int {
        failureCounts[connectorId] ?? 0
    }

    /// How long to wait before the next attempt: the cadence the user chose
    /// while the connector is healthy, a growing backoff while it is failing,
    /// and never longer than that cadence either way.
    ///
    /// Worth being plain about which direction this moves, because "backoff"
    /// suggests the other one: the clip is to the connector's OWN interval, so
    /// a failing connector is retried SOONER than its cadence and decays back
    /// towards it, rather than ever being pushed past it. A blip on a
    /// half-hourly feed is retried in thirty seconds instead of costing the
    /// user half an hour of blank clock; a feed that is genuinely down doubles
    /// its way back to the half hour and settles there. It is the retry
    /// interval that is capped at the cadence, which is what the spec asks for.
    public func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval {
        let failures = consecutiveFailures(connectorId: connectorId)
        guard failures > 0 else { return interval }
        return min(retryPolicy.delay(afterConsecutiveFailures: failures), interval)
    }

    /// A run: it takes its turn, and its outcome is recorded against the
    /// connector.
    public func run(
        for connectorId: String, _ work: @escaping @Sendable () async -> RunResult
    ) async -> RunResult {
        let result = await queued(work)
        // Awaiting a task is not interrupted by cancellation, so this is
        // reached even when the caller gave up — which is the point. A run torn
        // down still has an outcome, and the backoff has to be told it was a
        // cancellation rather than left reading the last failure.
        record(result, for: connectorId)
        return result
    }

    /// A delivery that is not a run — the History's replay. It takes its turn
    /// exactly as a run does and is recorded against nothing: the backoff
    /// describes how the FEED is behaving, and hearing this morning's anecdote
    /// again is not evidence about anekdot.ru in either direction.
    public func deliver(_ work: @escaping @Sendable () async -> RunResult) async -> RunResult {
        await queued(work)
    }

    /// What a thrown error means for the delivery that raised it.
    ///
    /// One reading, shared by the produce and by the delivery, because the two
    /// halves must not classify the same error differently — a connector
    /// throwing `CancellationError` and a notify killed by the same quit are
    /// the same event seen from two places.
    ///
    /// `URLError(.cancelled)` is the transport naming this specific event
    /// rather than the ambient task state: `URLSession` reports a request
    /// killed by its task's cancellation that way, and app quit killing an
    /// in-flight notify is the ordinary producer. As typed as
    /// `CancellationError`, and it cannot swallow a device fault — those arrive
    /// as `AwtrixError.http`, never as a `URLError`.
    public static func classify(_ error: any Error) -> RunResult {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .failed(String(describing: error))
    }

    /// Reads the count off the OUTCOME, not off the path that produced it.
    ///
    /// There are three ways a run ends up `.cancelled` and they arrive from
    /// three different places — a connector throwing `CancellationError`, the
    /// transport reporting `URLError(.cancelled)`, and a delivery that got all
    /// the way through only to find the task torn down. Deciding here, on the
    /// one value all three become, is what stops the next guard added to the
    /// session's `send` from quietly re-classifying one of them.
    private func record(_ result: RunResult, for connectorId: String) {
        switch result {
        case .delivered:
            failureCounts[connectorId] = 0
        case .failed:
            failureCounts[connectorId, default: 0] += 1
        case .cancelled:
            // Not evidence about the feed. The user quitting, a connector
            // switched off mid-delivery, a schedule rebuilt — none of them say
            // whether the source is up. Counting one would back a healthy
            // connector off for having been interrupted; resetting on one would
            // clear a real backoff for the same non-reason.
            break
        case .skipped:
            // Never actually arrives. The session answers `.skipped` from its
            // enablement guard, before there is a run to have an outcome, so
            // this branch exists because the switch is exhaustive and not
            // because it decides anything — a mutation of it changes nothing,
            // and the rule it looks like it implements is pinned on that guard
            // instead. The answer would be the same either way: a connector the
            // user switched off has not failed, and has not recovered either.
            break
        }
    }

    /// Takes a place in the chain, waits for whatever is ahead, and runs `work`
    /// when it gets there.
    ///
    /// Claiming a place is a single actor-isolated step — there is no
    /// suspension between reading `tail` and writing it — so no caller can slip
    /// between the two and take the same place twice.
    ///
    /// Shared by both entry points rather than written twice, because a second
    /// copy is a second chain the moment one of them is edited, and two chains
    /// are no serialisation at all.
    private func queued(
        _ work: @escaping @Sendable () async -> RunResult
    ) async -> RunResult {
        let predecessor = tail
        let claimed = Task { () -> RunResult in
            await predecessor?.value
            // Checked on the far side of the wait. Cancellation cannot break
            // `predecessor?.value`, so without this a delivery cancelled while
            // queued goes on to put a banner up that nobody is waiting for.
            if Task.isCancelled { return .cancelled }
            return await work()
        }
        tail = Task { _ = await claimed.value }

        // `claimed` is unstructured, so it inherits neither the caller's
        // cancellation nor breaks on it when awaited. Forwarded by hand, or a
        // caller that gives up gets neither the work stopped nor itself back.
        return await withTaskCancellationHandler {
            await claimed.value
        } onCancel: {
            claimed.cancel()
        }
    }
}
