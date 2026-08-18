import Foundation

/// How long to hold off after a run failed, as a pure function of how many runs
/// in a row have failed.
///
/// A type of its own rather than three lines inside the host, because the whole
/// of the timing decision is arithmetic over one integer: it is decided in a
/// test that costs microseconds instead of one that waits out real seconds.
public struct RetryPolicy: Sendable {
    /// What the first failure is worth. Every one after doubles it.
    public let base: TimeInterval
    /// The ceiling the doubling runs into. The host clips again, to the
    /// connector's own interval — see `ConnectorHost.nextDelay(connectorId:interval:)`.
    public let cap: TimeInterval

    public init(base: TimeInterval = 30, cap: TimeInterval = 1800) {
        self.base = base
        self.cap = cap
    }

    /// Zero while nothing has failed: a healthy connector is not held off at
    /// all, and the count reaching here is the count of failures BEHIND the
    /// wait, so the first one is worth `base` rather than twice it.
    ///
    /// A very large count is not a special case. The doubling saturates at
    /// `TimeInterval.infinity`, which the cap clips exactly as it clips a
    /// merely large number, so there is no count this has to be defended from.
    public func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let grown = base * pow(2, Double(failures - 1))
        // Clipped after the growth, never before it: capping `base` and then
        // doubling that reads identically at one failure and is unbounded at
        // twenty.
        return min(grown, cap)
    }
}
