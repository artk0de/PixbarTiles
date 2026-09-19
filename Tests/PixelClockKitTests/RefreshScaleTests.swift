// Tests/PixelClockKitTests/RefreshScaleTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Test func theScaleRunsFromHalfAMinuteToHalfADay() {
    #expect(RefreshScale.steps.count == 27)
    #expect(Array(RefreshScale.steps.prefix(5)) == [30, 60, 120, 180, 300])
    #expect(RefreshScale.steps[26] == 12 * 3600)
}

// The part above three minutes is the old scale, not a copy of it.
@Test func theStepsFromFiveMinutesUpAreTheIntervalScaleUnchanged() {
    #expect(Array(RefreshScale.steps.dropFirst(4)) == IntervalScale.positions)
}

@Test func theStepsOnlyEverGrow() {
    let steps = RefreshScale.steps
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
}

// Thirty seconds for every connector, whatever is stored.
@Test func nothingRunsMoreOftenThanEveryThirtySeconds() {
    for seconds: TimeInterval in [-60, 0, 1, 29, 30] {
        #expect(RefreshScale.snapped(seconds) == 30, "\(seconds) s")
    }
    #expect(RefreshScale.shortest == 30)
}

@Test func everyStepReadsBackAsItself() {
    for step in RefreshScale.steps {
        #expect(RefreshScale.snapped(step) == step)
    }
}

@Test func aValueBetweenStepsReadsAsTheNearestOne() {
    #expect(RefreshScale.snapped(44) == 30)
    #expect(RefreshScale.snapped(50) == 60)
    #expect(RefreshScale.snapped(250) == 300)
    #expect(RefreshScale.snapped(100_000) == 12 * 3600)
}

@Test func aValueExactlyBetweenTwoStepsTakesTheLongerOne() {
    #expect(RefreshScale.snapped(45) == 60)
    #expect(RefreshScale.snapped(240) == 300)
    #expect(RefreshScale.snapped(5_400) == 7_200)
}

// Index → duration → seconds. Reading the stored index against the new scale
// instead would turn every half-hourly anecdote into one every ten minutes.
@Test func aStoredIntervalPositionMigratesToTheDurationItMeant() {
    #expect(RefreshScale.seconds(migratingIntervalPosition: 0) == 300)
    #expect(RefreshScale.seconds(migratingIntervalPosition: 5) == 1_800)
    #expect(RefreshScale.seconds(migratingIntervalPosition: 22) == 43_200)
}

@Test func anOutOfRangePositionMigratesToTheEndItFellOff() {
    #expect(RefreshScale.seconds(migratingIntervalPosition: -3) == 300)
    #expect(RefreshScale.seconds(migratingIntervalPosition: 99) == 43_200)
}

@Test func everyMigratedIntervalIsAStepOfTheNewScale() {
    for position in IntervalScale.positions.indices {
        let seconds = TimeInterval(RefreshScale.seconds(migratingIntervalPosition: position))
        #expect(RefreshScale.snapped(seconds) == seconds, "position \(position)")
    }
}
