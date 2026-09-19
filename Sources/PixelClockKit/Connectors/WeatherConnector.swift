import Foundation

/// The weather where the clock is: the sky as a device-wide overlay, the
/// temperature as an app in the loop.
///
/// The two are deliberately separate. `OVERLAY` is the firmware's own weather
/// layer and draws over everything on screen — rain on the matrix when it
/// rains — but it draws weather, not numbers; the reading needs an app of its
/// own, and an app is where a colour is legitimate. An earlier design built
/// rain out of a catalogue GIF and the `Matrix` effect: that list is decorative
/// and belongs to custom apps, and rebuilding it would be a worse rain drawn
/// over a device that already has one.
///
/// A source of content like every other connector: it reaches the weather
/// service and never the clock. What is written to the device, and what has to
/// be remembered before it is written, belongs to `AwtrixClockSession` and
/// `DeviceCustody`.
public struct WeatherConnector: Connector {
    /// The name this app's reading lives under in the device's loop. One name,
    /// so a poll replaces the previous reading rather than adding to a rotation
    /// that grows all day.
    public static let appName = "weather"

    public let id = "weather"
    public let displayName = "Weather"
    /// How often the CLOCK is refreshed — which is a different question from
    /// how often the SERVICE has something new, and the two numbers are
    /// deliberately no longer one.
    ///
    /// 900 is the service's own update cadence and it stays where it belongs,
    /// as the window `OpenMeteoSource` answers from its cache: that is what
    /// keeps this app off a free public API between updates, and it is not
    /// affected by anything here. 600 is this app writing to the device. A poll
    /// that lands inside the cache window reaches no network at all and
    /// re-pushes the reading it already had — which is not waste, it is the
    /// point: the output carries `lifetime: 3600`, so the app drops out of the
    /// device's loop an hour after the last delivery. At 600 seconds six
    /// refreshes fit inside that hour, so five consecutive failures are
    /// survivable; at 900 only four fit, and three failures put the temperature
    /// off the clock.
    ///
    /// Whoever changes one of these must look at the other. Refreshing the
    /// clock LESS often than the service updates would show a stale reading;
    /// refreshing it so rarely that fewer than a handful fit inside `lifetime`
    /// puts a blank slot on the matrix the first time the network hiccups.
    public let defaultInterval: TimeInterval = 600
    public var defaultPolicy: TilePolicy { TileDefaults.weather }
    /// Nothing here is heard. The reading is drawn into the device's own loop
    /// and the sky is a setting on the matrix — no speech, no jingle, nothing
    /// that reaches the room. So the two quiet rules do not apply to it: a
    /// Focus and a busy microphone exist to stop the app SPEAKING, and holding
    /// this connector through the shipped nine-hour window froze the
    /// temperature on the clock until morning.
    public let isAudible = false

    /// Ambient, and this is the property the panel reads. The reading is kept
    /// fresh in the device's own loop, which means it is on the matrix already:
    /// there is nothing here to trigger — running it by hand asks the sky for
    /// the same number a quarter of an hour early — and nothing to witness,
    /// because the result of a poll IS what the clock is showing. A row would
    /// carry a "Run now" that repaints what is on screen and a switch that is a
    /// setting, which is what the gear is for.
    ///
    /// A separate claim from `isAudible` above rather than a restatement of it.
    /// That one is about the room and answers the Focus and the microphone;
    /// this one is about the panel. Silence happens to follow from being
    /// ambient here, but it does not run the other way: the connectors coming
    /// next are silent WITHOUT being ambient, and they keep their rows.
    public let isAmbient = true

    private let source: OpenMeteoSource
    /// Read on every read rather than held, so a location typed into the
    /// settings takes effect at the next poll instead of at the next launch.
    private let location: @Sendable () -> Coordinates

    public init(source: OpenMeteoSource, location: @escaping @Sendable () -> Coordinates) {
        self.source = source
        self.location = location
    }

    /// Goes out for the sky where the clock is. Nothing is drawn here; see
    /// `output(for:)`.
    public func read() async throws -> WeatherReading {
        try await source.reading(at: location())
    }

    public var awtrixFace: AwtrixFace<WeatherReading> {
        AwtrixFace { Self.output(for: $0) }
    }

    /// What a reading looks like on the matrix.
    ///
    /// Separated from `read()` so the drawing can be tested against a reading
    /// rather than against a network, as `ClaudeUsageConnector.output(for:)`
    /// already is.
    static func output(for reading: WeatherReading) -> AwtrixDelivery {
        let theme = WeatherTheme(code: reading.code, isDay: reading.isDay)
        // Two quantities in one element: the digits are the AIR temperature,
        // which is what a thermometer would agree with, and the colour is what
        // that feels like. Collapsing them — showing the apparent temperature —
        // gains one number and loses the other. Falling back to the air
        // temperature when the service omitted the felt one, because a reading
        // with no colour is drawn in whatever the previous app left behind.
        let felt = reading.apparentTemperature ?? reading.temperature
        return AwtrixDelivery(
            text: Self.degrees(reading.temperature),
            // The sky, drawn inside the app rather than over the whole matrix.
            // The overlay below already carries it to the device, but four
            // skies share `clear` there and night is not a layer at all — so on
            // an overcast evening the clock shows a number and nothing else.
            // The icon is what distinguishes the eleven, in the eight pixels next
            // to the reading they belong to.
            icon: theme.icon,
            color: TemperatureColour(celsius: felt).hex,
            surface: .app(Self.appName),
            // An hour without a fresh reading and the clock drops the app on
            // its own — the only thing that survives this process ending
            // without a quit. An hour rather than something tighter because of
            // what the poll fits inside it: at `defaultInterval`'s 600 seconds
            // that is six refreshes, so five in a row have to fail before the
            // temperature leaves the loop, and a network hiccup or one slow
            // answer from a free public service cannot strip it off while this
            // app is alive and about to succeed. And an hour is where the
            // reading stops being weather anyway, so nothing is lost by waiting
            // that long to drop it.
            lifetime: 3_600,
            overlay: theme.overlay
        )
    }

    /// A temperature as eight pixels of height can show it.
    ///
    /// Whole degrees: the matrix is 32 by 8 and a decimal point costs two
    /// columns to say something nobody reads off a clock across a room.
    /// `rounded()` rather than truncation, so -3.6 is -4 rather than -3 — the
    /// wrong direction on the side of the scale where it matters.
    ///
    /// The scale is spelled out, and the columns it costs are the reason it was
    /// once left off. With the sky now drawn as an icon in the leading eight
    /// pixels, a bare `4°` left the rest of the row empty — and a lone degree
    /// sign is the one reading a person can misread as Fahrenheit without ever
    /// noticing they did. Four glyphs still fit beside the icon; the firmware
    /// scrolls anything that does not.
    static func degrees(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°C"
    }
}
