// Tests/PixbarKitTests/RefreshScaleTests.swift
import Foundation
import Testing
@testable import PixbarKit

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

// Thirty seconds on the general ladder, whatever is stored. The Coding
// Subscription tiles have a ladder of their own and a ten-second step on it.
@Test func nothingOnTheGeneralLadderRunsMoreOftenThanEveryThirtySeconds() {
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

// MARK: - The Coding Subscription ladder

// The Claude and z.ai tiles read a subscription's usage, and a person watching
// a limit move wants it read now rather than at the top of the next interval.
// Their own ladder, because ten seconds is not a cadence to hand the weather:
// a free forecast API answers a place every quarter of an hour, and offering
// 360 reads an hour there would be an invitation to be blocked.
@Test func theCodingSubscriptionLadderIsTheTwelveStepsItOffers() {
    #expect(
        RefreshScale.codingSubscription
            == [10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 14_400]
    )
}

@Test func theCodingSubscriptionLadderOnlyEverGrows() {
    let steps = RefreshScale.codingSubscription
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func aCodingSubscriptionTileCanRunEveryTenSeconds() {
    for seconds: TimeInterval in [-60, 0, 1, 10, 12] {
        #expect(RefreshScale.snapped(seconds, on: RefreshScale.codingSubscription) == 10, "\(seconds) s")
    }
}

@Test func everyCodingSubscriptionStepReadsBackAsItself() {
    for step in RefreshScale.codingSubscription {
        #expect(RefreshScale.snapped(step, on: RefreshScale.codingSubscription) == step)
    }
}

// The words the picker shows, and the words they were asked for.
@Test func theLadderSaysItsStepsTheWayTheyWereAskedFor() {
    #expect(
        RefreshScale.codingSubscription.map(RefreshScale.label)
            == [
                "10 s", "15 s", "30 s", "1 min", "2 min", "5 min", "10 min", "15 min",
                "30 min", "1 hour", "2 hours", "4 hours",
            ]
    )
}

// MARK: - The weather's fetch ladder

// How often the sky is READ, which is not how often the face changes what it
// shows: `changeEvery` runs three to fifteen seconds and is a different
// setting on a different control.
@Test func theWeatherFetchLadderRunsFromAMinuteToFourHours() {
    #expect(
        RefreshScale.weatherFetch
            == [60, 120, 180, 300, 600, 900, 1_800, 3_600, 7_200, 14_400]
    )
}

@Test func theWeatherFetchLadderOnlyEverGrows() {
    let steps = RefreshScale.weatherFetch
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
}

// A minute, not ten seconds: the source caches a place until its own cadence
// says otherwise, so a faster poll asks more of a free service and returns the
// same answer.
@Test func theWeatherIsNeverFetchedMoreOftenThanEveryMinute() {
    for seconds: TimeInterval in [-60, 0, 1, 10, 30, 59] {
        #expect(RefreshScale.snapped(seconds, on: RefreshScale.weatherFetch) == 60, "\(seconds) s")
    }
}

@Test func theWeatherFetchLadderSaysItsStepsTheWayTheyWereAskedFor() {
    #expect(
        RefreshScale.weatherFetch.map(RefreshScale.label)
            == [
                "1 min", "2 min", "3 min", "5 min", "10 min", "15 min", "30 min",
                "1 hour", "2 hours", "4 hours",
            ]
    )
}
