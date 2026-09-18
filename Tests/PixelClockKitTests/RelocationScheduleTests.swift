import Foundation
import Testing
@testable import PixelClockKit

// A clock that is answering has not moved, and looking for it would put
// multicast on the network to confirm what the last poll just said.
@Test func nothingIsDueWhileTheClockIsAnswering() {
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 0) == false)
}

// The first failure is worth a look. A lease that moved is indistinguishable
// from a clock that was unplugged a second ago, and the one that is cheap to
// fix is the one worth trying immediately.
@Test func theFirstFailedPollIsWorthALook() {
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 1))
}

@Test func everyDoublingOfTheOutageIsWorthAnotherLook() {
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 2))
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 4))
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 8))
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 1024))
}

// The whole of the rate limit. Without this the app browses once a minute for
// as long as the clock is away, which is the defect the panel's own browse gate
// was written to prevent, rebuilt with a counter in front of it.
@Test func theFailuresBetweenDoublingsAreNotWorthALook() {
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 3) == false)
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 5) == false)
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 6) == false)
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 7) == false)
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: 1000) == false)
}

// The number that says whether the rule is worth anything, stated as a test
// rather than left to arithmetic in a comment. A clock unplugged over a week,
// polled every minute, is 10,080 failures — and this is what it costs in
// browses. A fixed "every tenth failure" would be a thousand of them.
@Test func aWeekAwayCostsAboutADozenLooks() {
    let looks = (1...10_080).count { RelocationSchedule.isDue(afterConsecutiveFailures: $0) }

    #expect(looks == 14)
}

// A count cannot be negative, but the type it arrives in can be. Answering
// "yes, look" to nonsense would browse on a number nobody meant.
@Test func nonsenseIsNotWorthALook() {
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: -1) == false)
    #expect(RelocationSchedule.isDue(afterConsecutiveFailures: Int.min) == false)
}
