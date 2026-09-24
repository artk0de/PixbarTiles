import Foundation
import Testing
@testable import PixbarKit

@Test func scaleHasTwentyThreePositions() {
    #expect(IntervalScale.positions.count == 23)
}

@Test func firstTwelvePositionsStepFiveMinutesToOneHour() {
    #expect(IntervalScale.duration(atPosition: 0) == 5 * 60)
    #expect(IntervalScale.duration(atPosition: 1) == 10 * 60)
    #expect(IntervalScale.duration(atPosition: 11) == 60 * 60)
}

@Test func remainingPositionsStepOneHourToTwelve() {
    #expect(IntervalScale.duration(atPosition: 12) == 2 * 3600)
    #expect(IntervalScale.duration(atPosition: 22) == 12 * 3600)
}

@Test func positionsAreStrictlyIncreasing() {
    let values = IntervalScale.positions
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func outOfRangePositionsClampInsteadOfCrashing() {
    #expect(IntervalScale.duration(atPosition: -5) == 5 * 60)
    #expect(IntervalScale.duration(atPosition: 999) == 12 * 3600)
}

@Test func positionForDurationSnapsToTheNearestStep() {
    #expect(IntervalScale.position(for: 5 * 60) == 0)
    #expect(IntervalScale.position(for: 8 * 60) == 1)      // nearer 10 than 5
    #expect(IntervalScale.position(for: 3 * 3600) == 13)
}

@Test func labelsReadAsMinutesThenHours() {
    #expect(IntervalScale.label(atPosition: 0) == "5 min")
    #expect(IntervalScale.label(atPosition: 11) == "1 h")
    #expect(IntervalScale.label(atPosition: 22) == "12 h")
}
