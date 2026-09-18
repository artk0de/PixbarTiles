import Foundation
import Testing

/// How long a poll in this target waits before it gives up.
///
/// One number for the whole target, and the reason it is a constant rather than
/// a default written at each helper is that the number drifted exactly that
/// way. The raise from two seconds to five landed on the app target's copy and
/// not on this one, and `startingAgainReplacesTheBrowseRatherThanAddingOne`
/// went red four times in a single 30-run pass because of the copy left behind.
/// One rule, two mechanisms, already diverged.
///
/// The same five seconds as `PixelClockTilesAppTests/Doubles.swift`. Test
/// targets cannot import each other, so the budget is stated twice on purpose —
/// and each statement is pinned by a test named for the agreement, so lowering
/// either one fails with a message that says what it is.
let pollingBudget: TimeInterval = 5

/// The budget a poll with no limit of its own uses.
///
/// A function rather than a default argument, and that is the whole point: a
/// default argument cannot be read back by anything, which is exactly why one
/// copy of this rule sat at two seconds for as long as it did. Resolved here,
/// the number has one site per target and a test can state it.
func waitBudget(_ limit: TimeInterval?) -> TimeInterval { limit ?? pollingBudget }

// Both test targets share one machine, one main actor and a growing population
// of synchronous renders, so this is headroom against LOAD rather than against
// the work being waited for. It has to be the same headroom on both sides or
// the tighter side is the one that flakes, which is what happened.
@Test func theWaitBudgetInTheKitTestsIsTheFiveSecondsTheAppTestsAlsoUse() {
    #expect(waitBudget(nil) == 5)
    // And a caller that names its own window still gets it: the constant is the
    // fallback, not an override.
    #expect(waitBudget(0.05) == 0.05)
}
