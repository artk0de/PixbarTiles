import Foundation
import Testing
@testable import PixbarTilesApp

/// The lamp of a clock being checked blinks: lit, then dark, in whole
/// halves of a beat — a pixel lamp switches, it does not fade.
@Suite struct CheckingBlinkTests {
    @Test func theLampIsLitForTheFirstHalfOfEachBeatAndDarkForTheSecond() {
        let half = CheckingBlink.halfBeat
        #expect(CheckingBlink.isLit(elapsed: 0))
        #expect(CheckingBlink.isLit(elapsed: half * 0.9))
        #expect(CheckingBlink.isLit(elapsed: half * 1.1) == false)
        #expect(CheckingBlink.isLit(elapsed: half * 2.1))
        #expect(CheckingBlink.isLit(elapsed: half * 3.5) == false)
    }
}
