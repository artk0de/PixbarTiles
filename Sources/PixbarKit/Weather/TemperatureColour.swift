import Foundation

/// A temperature as a colour the clock can be told to draw a reading in.
///
/// The colour answers a different question from the digits it is drawn under:
/// the number says how many degrees it is, the colour says how that feels. Two
/// quantities in one element, which is why the reading is not simply replaced
/// by the apparent temperature — a clock that disagreed with every other
/// thermometer in the room would be read as broken rather than as informative.
///
/// Eight stops rather than two. Interpolating straight from blue to red passes
/// through purple, which is not a temperature anybody recognises; the colours
/// in between are the scale, and they are what makes a glance readable without
/// the number.
public struct TemperatureColour: Sendable, Equatable {
    /// One point on the gradient: the temperature it stands for, and the
    /// channels it is drawn in.
    public struct Stop: Sendable, Equatable {
        public let celsius: Double
        /// Held as `Double` because interpolating is the only thing ever done
        /// with them — as bytes, every blend would be a pair of conversions
        /// around the arithmetic that matters.
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ celsius: Double, _ red: Double, _ green: Double, _ blue: Double) {
            self.celsius = celsius
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Deep blue, blue, cyan, teal, green, yellow, orange, red — with the
    /// spacing tightened above freezing, where a degree is something a person
    /// acts on and the difference has to be visible.
    ///
    /// Every stop keeps a channel at or near full, and that is a hardware
    /// constraint rather than taste: the clock runs at brightness 2, read back
    /// from its own `/api/settings`, and at brightness 2 a dark navy and an
    /// unlit pixel are the same thing. Cold is expressed as BLUE, never as DIM
    /// — the obvious gradient, which fades towards black at the cold end, puts
    /// the coldest readings on a matrix that looks switched off.
    public static let stops: [Stop] = [
        Stop(-20, 51, 51, 255),
        Stop(-10, 51, 136, 255),
        Stop(0, 51, 229, 255),
        Stop(7, 51, 255, 204),
        Stop(14, 51, 255, 51),
        Stop(21, 255, 255, 51),
        Stop(28, 255, 153, 51),
        Stop(35, 255, 34, 0),
    ]

    /// Six hex digits behind a hash, which is the only form the firmware
    /// parses. Anything else is dropped without a word and the reading comes
    /// out in whatever colour the previous app left behind, so a malformed
    /// colour is invisible rather than an error.
    public let hex: String

    public init(celsius: Double) {
        hex = Self.drawn(at: celsius)
    }

    private static func drawn(at celsius: Double) -> String {
        let table = stops
        // Held rather than extrapolated past either end: there is no next stop
        // to aim at, and continuing the slope runs the channels off the end of
        // a byte — a -50 would ask for a blue beyond #0000FF and come out as
        // three hex digits the firmware ignores.
        guard celsius > table[0].celsius else { return rendered(table[0]) }

        for index in 1..<table.count where celsius <= table[index].celsius {
            let lower = table[index - 1]
            let upper = table[index]
            let progress = (celsius - lower.celsius) / (upper.celsius - lower.celsius)
            return rendered(
                red: lower.red + (upper.red - lower.red) * progress,
                green: lower.green + (upper.green - lower.green) * progress,
                blue: lower.blue + (upper.blue - lower.blue) * progress
            )
        }
        return rendered(table[table.count - 1])
    }

    private static func rendered(_ stop: Stop) -> String {
        rendered(red: stop.red, green: stop.green, blue: stop.blue)
    }

    /// A channel on an exact half rounds to even — the approved weather
    /// design's arithmetic (`wgen.temp_colour`, Python's `round()`), so the
    /// TC001 and the TC002 draw one temperature in one colour.
    private static func rendered(red: Double, green: Double, blue: Double) -> String {
        String(
            format: "#%02X%02X%02X",
            Int(red.rounded(.toNearestOrEven)), Int(green.rounded(.toNearestOrEven)),
            Int(blue.rounded(.toNearestOrEven))
        )
    }
}
