import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Every stepped choice in the tile settings is a slider over the SAME steps
// its picker offered: a uniform ladder by value, a non-uniform one by index,
// with the stored value's label beside it. What a slider may write is the
// value under the thumb when the drag ENDS — a write per step during a drag
// would push the clock once per step.

// MARK: - The ladder

@Suite struct StepLadderTests {
    // 0 … 100 in fives is uniform: the slider runs over the values themselves.
    @Test func aUniformLadderSlidesOverItsValues() {
        let ladder = StepLadder([0, 5, 10, 15])
        #expect(ladder.isUniform)
        #expect(ladder.track == 0...15)
        #expect(ladder.stride == 5)
        #expect(ladder.position(for: 10) == 10)
        #expect(ladder.value(at: 10) == 10)
    }

    // 5 s, 10 s, 15 s, 30 s … is not: the slider runs over the ladder's index,
    // so every step is an equal stretch of track.
    @Test func aNonUniformLadderSlidesOverItsIndex() {
        let ladder = StepLadder([5, 10, 15, 30, 60, 120, 300])
        #expect(ladder.isUniform == false)
        #expect(ladder.track == 0...6)
        #expect(ladder.stride == 1)
        #expect(ladder.position(for: 60) == 4)
        #expect(ladder.value(at: 4) == 60)
    }

    // A stored value the ladder does not offer shows at its nearest step,
    // and a tie goes to the longer one — `RefreshScale.snapped`'s rule.
    @Test func anOffLadderValueShowsAtTheNearestStep() {
        let ladder = StepLadder([5, 10, 15, 30, 60, 120, 300])
        #expect(ladder.snapped(20) == 15)
        #expect(ladder.snapped(45) == 60)
        #expect(ladder.snapped(1) == 5)
        #expect(ladder.snapped(9_000) == 300)
        #expect(ladder.position(for: 45) == 4)
    }

    // A position between two steps — a mid-drag reading — lands on a step,
    // and a position off either end is the end.
    @Test func aPositionLandsOnAStepAndIsClamped() {
        let index = StepLadder([5, 10, 15, 30])
        #expect(index.value(at: 1.4) == 10)
        #expect(index.value(at: 1.6) == 15)
        #expect(index.value(at: -3) == 5)
        #expect(index.value(at: 99) == 30)

        let uniform = StepLadder([0, 5, 10])
        #expect(uniform.value(at: 6) == 5)
        #expect(uniform.value(at: 8) == 10)
        #expect(uniform.value(at: 400) == 10)
    }

    @Test func theStepsAreSortedAndUnique() {
        #expect(StepLadder([30, 5, 10, 5]).steps == [5, 10, 30])
    }
}

// MARK: - Commit on release

@Suite struct SlideCommitTests {
    // A drag moves the thumb and writes nothing until it lets go, and then
    // writes where it let go.
    @Test func aDragWritesOnceWhenItEnds() {
        var slide = SlideCommit()
        slide.begin()
        #expect(slide.move(to: 3) == nil)
        #expect(slide.move(to: 4) == nil)
        #expect(slide.shown == 4)
        #expect(slide.end() == 4)
        #expect(slide.shown == nil)
    }

    // A move that is no drag — an arrow key, VoiceOver's increment — has no
    // release to wait for, so it is the write itself.
    @Test func aMoveOutsideADragWritesAtOnce() {
        var slide = SlideCommit()
        #expect(slide.move(to: 2) == 2)
        #expect(slide.shown == nil)
    }

    // A click that never moved the thumb writes nothing.
    @Test func aDragThatNeverMovedWritesNothing() {
        var slide = SlideCommit()
        slide.begin()
        #expect(slide.end() == nil)
    }
}

// MARK: - The ranges the design names

@Suite struct SliderRangeTests {
    // "Show reset after" runs 0 … 100 % in fives now, so a row can name its
    // reset from the first percent.
    @Test func showResetAfterRunsFromZeroToAHundredInFives() {
        #expect(CodeUsage.Parameters.resetAfterSteps == Array(stride(from: 0, through: 100, by: 5)))
        #expect(StepLadder(CodeUsage.Parameters.resetAfterSteps.map(Double.init)).isUniform)
    }
}
