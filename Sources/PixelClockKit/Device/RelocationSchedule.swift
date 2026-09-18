import Foundation

/// How often, during an outage, the app may go looking for where the clock
/// went.
///
/// A pure function of one integer, for `RetryPolicy`'s reason: the whole of the
/// timing decision is arithmetic, and arithmetic is decided in a test that
/// costs microseconds instead of one that waits out real seconds.
///
/// It counts failed polls rather than seconds, and that is the deliberate part.
/// The polls are a fixed cadence, so the count IS the elapsed time in the only
/// unit the caller already holds — no clock to inject, no "last attempted at"
/// to keep, and no way for the two to disagree after a sleep or a wake.
///
/// Doubling rather than a fixed interval, because the two failure modes want
/// opposite things. A lease that moved is fixed by one look, so the first
/// failure is worth one immediately. A clock unplugged over a holiday cannot be
/// fixed by looking at all, and every look at it is multicast on somebody's
/// network — so the gaps grow, and a week away costs fourteen browses instead
/// of ten thousand.
public enum RelocationSchedule {
    /// Whether to look for the clock now, having failed to reach it this many
    /// times in a row.
    public static func isDue(afterConsecutiveFailures failures: Int) -> Bool {
        // Powers of two: 1, 2, 4, 8, … A count of zero is a clock that is
        // answering, and a negative one is a caller with a defect — neither is
        // a reason to browse. Written as the bit trick rather than a running
        // "next attempt at" so that this stays a function of its argument
        // alone, answerable for any count in any order.
        failures > 0 && failures & (failures - 1) == 0
    }
}
