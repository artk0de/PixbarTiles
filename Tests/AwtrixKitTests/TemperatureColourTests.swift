import Foundation
import Testing
@testable import AwtrixKit

// The colour the reading is drawn in, which answers a different question from
// the digits beside it: the number says how many degrees, the colour says how
// that feels.
//
// The device runs at brightness 2 — read back from its own `/api/settings` —
// and at that brightness a dark navy is indistinguishable from a pixel that is
// simply off. So every colour this can produce has to stay bright and
// saturated, and cold has to be expressed as BLUE rather than as DIM. That is a
// property of the whole range rather than of the eight stops, which is why it
// is asserted by sweeping it rather than by reading the table.

/// The gradient, written down separately from the table that produces it.
///
/// Deliberately a second statement rather than something read off
/// `TemperatureColour.stops`: derived, it would agree with any digit fumbled
/// into a stop, and a wrong colour is the one failure the device cannot report
/// — the firmware parses six hex digits behind a hash and silently ignores
/// anything else, so a malformed colour is invisible rather than an error.
private let gradient: [(celsius: Double, hex: String, what: String)] = [
    (-20, "#3333FF", "deep blue"),
    (-10, "#3388FF", "blue"),
    (0, "#33E5FF", "cyan"),
    (7, "#33FFCC", "teal"),
    (14, "#33FF33", "green"),
    (21, "#FFFF33", "yellow"),
    (28, "#FF9933", "orange"),
    (35, "#FF2200", "red"),
]

/// The three channels behind the hash, read back out of what the device would
/// be sent — the output itself rather than the numbers that made it.
private func channels(_ hex: String) -> (red: Int, green: Int, blue: Int) {
    let digits = Array(hex.dropFirst())
    func byte(_ index: Int) -> Int {
        Int(String(digits[index...(index + 1)]), radix: 16) ?? -1
    }
    return (byte(0), byte(2), byte(4))
}

@Test func eachStopOfTheGradientIsDrawnExactlyAsItIsWrittenDown() {
    for stop in gradient {
        #expect(
            TemperatureColour(celsius: stop.celsius).hex == stop.hex,
            "\(stop.celsius)° (\(stop.what)) drew \(TemperatureColour(celsius: stop.celsius).hex)"
        )
    }
    // And the table under test holds these eight and nothing else, or a ninth
    // stop could sit between two of them unchecked.
    #expect(TemperatureColour.stops.map(\.celsius) == gradient.map(\.celsius))
}

// Blue through to red WITH the colours in between. A two-stop interpolation
// from blue to red passes through muddy purple, which says nothing about
// temperature and is not what a gradient is for.
@Test func theGradientPassesThroughTheColoursBetweenBlueAndRed() {
    let drawn = gradient.map { TemperatureColour(celsius: $0.celsius).hex }

    #expect(Set(drawn).count == gradient.count)
    // The middle of the range is green, not the purple a blue-to-red blend
    // would put there.
    let middle = channels(TemperatureColour(celsius: 14).hex)
    #expect(middle.green > middle.red)
    #expect(middle.green > middle.blue)
}

@Test func aTemperatureBetweenTwoStopsIsBlendedFromBoth() {
    // Halfway from green to yellow: red climbs from 0x33 to 0xFF and nothing
    // else moves.
    #expect(TemperatureColour(celsius: 17.5).hex == "#99FF33")

    for (lower, upper) in zip(gradient, gradient.dropFirst()) {
        let midpoint = TemperatureColour(celsius: (lower.celsius + upper.celsius) / 2).hex
        let blend = channels(midpoint)
        let below = channels(lower.hex)
        let above = channels(upper.hex)

        for (channel, ends) in [
            ("red", (blend.red, below.red, above.red)),
            ("green", (blend.green, below.green, above.green)),
            ("blue", (blend.blue, below.blue, above.blue)),
        ] {
            let (mid, from, to) = ends
            #expect(
                mid >= min(from, to) && mid <= max(from, to),
                "\(lower.what)->\(upper.what): \(channel) \(mid) is outside \(from)...\(to)"
            )
        }
    }
}

@Test func pastEitherEndOfTheGradientTheLastStopIsHeldRatherThanExtrapolated() {
    // There is no stop beyond either end to aim at, and extrapolating runs the
    // channels off the end of a byte — a -50 asking for a blue past #0000FF
    // comes out as an overflow rather than as a colour.
    for freezing in [-20.0, -21, -40, -273.15] {
        #expect(TemperatureColour(celsius: freezing).hex == gradient[0].hex)
    }
    for baking in [35.0, 36, 60, 1_000] {
        #expect(TemperatureColour(celsius: baking).hex == gradient[gradient.count - 1].hex)
    }
}

// The firmware takes six hex digits behind a hash and drops anything else
// without a word, which leaves the reading in whatever colour the previous app
// was drawn in. So a malformed colour is not an error anywhere — it is a
// weather app that quietly wears the anecdote's colour.
@Test func everyColourInTheRangeIsOneTheFirmwareParses() {
    for step in stride(from: -40.0, through: 60.0, by: 0.25) {
        let hex = TemperatureColour(celsius: step).hex

        #expect(hex.wholeMatch(of: #/#[0-9A-F]{6}/#) != nil, "\(step)° drew \(hex)")
    }
}

// The constraint that is not obvious and cannot be seen in the table: the clock
// runs at brightness 2, and at brightness 2 a dark navy and an unlit pixel are
// the same thing. Cold is blue, not dim.
@Test func noTemperatureIsDrawnInAColourThatDisappearsAtBrightnessTwo() {
    for step in stride(from: -40.0, through: 60.0, by: 0.25) {
        let (red, green, blue) = channels(TemperatureColour(celsius: step).hex)
        let brightest = max(red, green, blue)
        let dimmest = min(red, green, blue)

        // At or near full. The measured worst case is 238, where cyan hands
        // over to teal and blue is falling while green is still climbing.
        #expect(brightest >= 200, "\(step)° drew a brightest channel of \(brightest)")
        // And saturated: a grey at this brightness reads as a fault rather than
        // as a temperature.
        #expect(brightest - dimmest >= 128, "\(step)° drew a near-grey")
    }
}

@Test func theColdEndOfTheGradientIsBlueRatherThanDark() {
    for freezing in [-40.0, -20, -15, -10] {
        let (red, green, blue) = channels(TemperatureColour(celsius: freezing).hex)

        #expect(blue == 255, "\(freezing)° drew blue at \(blue)")
        #expect(blue > red)
        #expect(blue > green)
    }
    // And the hot end is red the same way, or the gradient is only half a
    // scale.
    let hot = channels(TemperatureColour(celsius: 35).hex)
    #expect(hot.red == 255)
    #expect(hot.red > hot.blue)
}
