// Tests/PixelClockTilesAppTests/PixelGradientTests.swift
import Foundation
import Testing
@testable import PixelClockTilesApp

// What makes a gradient read as PIXEL art is the quantisation, not the block
// size: a ramp cut into a handful of steps is one somebody could have placed a
// cell at a time, while the same grid carrying a continuous ramp is a blurred
// rectangle with visible seams. So the banding is what is pinned here.

private func ramp(steps: Int = 7, from: Double = 1, to: Double = 0) -> [Double] {
    stride(from: 0.0, through: 1.0, by: 0.01).map {
        PixelGradient.opacity(at: $0, from: from, to: to, steps: steps)
    }
}

@Test func theRampTakesExactlyTheStepsItIsAllowed() {
    #expect(Set(ramp(steps: 7)).count == 7)
    #expect(Set(ramp(steps: 3)).count == 3)
}

// Both ends land ON the values asked for. A last band one step short of `to`
// is the off-by-one this exists to catch.
@Test func theRampStartsAndEndsWhereItSaysItDoes() {
    #expect(PixelGradient.opacity(at: 0, from: 0.9, to: 0.2, steps: 7) == 0.9)
    #expect(PixelGradient.opacity(at: 1, from: 0.9, to: 0.2, steps: 7) == 0.2)
}

@Test func theRampOnlyEverFallsWhenItStartsHigher() {
    let values = ramp(from: 0.9, to: 0.1)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 })
}

@Test func theRampOnlyEverRisesWhenItStartsLower() {
    let values = ramp(from: 0.1, to: 0.9)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
}

// A position off either end is clamped rather than extrapolated: the corner
// block of a rectangle whose size does not divide by the block size lands
// slightly past one.
@Test func aPositionOffTheEndIsClampedRatherThanExtrapolated() {
    #expect(PixelGradient.opacity(at: -0.5, from: 0.8, to: 0.2, steps: 7) == 0.8)
    #expect(PixelGradient.opacity(at: 1.5, from: 0.8, to: 0.2, steps: 7) == 0.2)
}

// One step is one colour, not a division by zero.
@Test func aSingleStepIsAFlatFill() {
    for position in [0.0, 0.5, 1.0] {
        #expect(PixelGradient.opacity(at: position, from: 0.7, to: 0.1, steps: 1) == 0.7)
    }
}
