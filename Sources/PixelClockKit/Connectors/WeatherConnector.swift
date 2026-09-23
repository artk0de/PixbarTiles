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
    /// The tile's name as every surface says it — the store card, the panel's
    /// row, the settings window's title. The spec's own name for it.
    public let displayName = "Better Weather"
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
    /// Read on every draw for the same reason: the tile's own settings — the
    /// scale, the humidity, the felt temperature — reach the next poll, not
    /// the next launch. The provider is who the stored config answers through;
    /// the preview passes its draft instead, and the SAME face code draws
    /// both, which is what keeps a preview from being able to lie. No default
    /// on purpose: the shipped wiring answers from the stored tile record, and
    /// a silent guess here would draw a tile nobody configured.
    private let config: @Sendable () -> WeatherTileConfig

    public init(
        source: OpenMeteoSource,
        location: @escaping @Sendable () -> Coordinates,
        config: @escaping @Sendable () -> WeatherTileConfig
    ) {
        self.source = source
        self.location = location
        self.config = config
    }

    /// Goes out for the sky where the clock is. Nothing is drawn here; see
    /// `output(for:)`.
    public func read() async throws -> WeatherReading {
        try await source.reading(at: location())
    }

    /// The sky at a place the CALLER names, rather than the one the tile has
    /// stored.
    ///
    /// The preview's own entry. Its controls edit a draft, and the place is
    /// one of them: read through `read()` the preview answered the SAVED
    /// place, so typing a new city changed the words under the field and
    /// nothing on the panel beside it. The source caches per coordinate, so
    /// asking for a place twice costs one request.
    public func reading(at place: Coordinates) async throws -> WeatherReading {
        try await source.reading(at: place)
    }

    public var awtrixFace: AwtrixFace<WeatherReading> {
        AwtrixFace { Self.output(for: $0, config: config()) }
    }

    public var ulanziFace: UlanziFace<WeatherReading>? {
        UlanziFace { Self.ulanziOutput(for: $0, config: config()) }
    }

    /// What a reading looks like on the matrix.
    ///
    /// Separated from `read()` so the drawing can be tested against a reading
    /// rather than against a network, as `ClaudeUsageConnector.output(for:)`
    /// already is.
    /// Public for the same reason `canvas(for:config:)` is: the preview IS a
    /// caller, and it draws the DRAFT rather than the stored config — through
    /// this very function, so what it shows cannot be a different drawing
    /// from what a poll sends.
    public static func output(
        for reading: WeatherReading, config: WeatherTileConfig
    ) -> AwtrixDelivery {
        return AwtrixDelivery(
            text: Self.degrees(reading.temperature, units: config.units),
            // The sky, drawn inside the app rather than over the whole matrix.
            // The overlay below already carries it to the device, but four
            // skies share `clear` there and night is not a layer at all — so on
            // an overcast evening the clock shows a number and nothing else.
            // The icon is what distinguishes the eleven, in the eight pixels next
            // to the reading they belong to.
            icon: WeatherTheme(code: reading.code, isDay: reading.isDay).icon,
            color: TemperatureColour(celsius: Self.colourTemperature(reading, config: config)).hex,
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
            overlay: WeatherTheme(code: reading.code, isDay: reading.isDay).overlay
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
    static func degrees(_ celsius: Double, units: WeatherTileConfig.Units) -> String {
        switch units {
        case .celsius: "\(Int(celsius.rounded()))°C"
        case .fahrenheit: "\(Int(Self.fahrenheit(celsius).rounded()))°F"
        }
    }

    /// What a reading looks like on the TC002's 52×16 panel: the weather
    /// face (`WeatherFace`), in the tile's layout, timed from now and told in
    /// the Mac's time zone. Each poll's push restarts its cycle.
    static func ulanziOutput(
        for reading: WeatherReading, config: WeatherTileConfig
    ) -> UlanziDelivery {
        WeatherFace.delivery(reading: reading, config: config, now: Date(), timeZone: .current)
    }

    /// The TC002's former still raster — the temperature at scale 2 over a
    /// humidity and feels-like band. The clock no longer receives it
    /// (`ulanziOutput` ships `WeatherFace`); it stays public because the
    /// tile settings window's preview still renders it until that preview
    /// plays `WeatherFace.preview`.
    public static func canvas(
        for reading: WeatherReading, config: WeatherTileConfig
    ) -> PixelCanvas {
        var canvas = PixelCanvas()
        let felt = reading.apparentTemperature ?? reading.temperature
        let ink = Pixel(
            colour: UlanziColour(
                hex: TemperatureColour(celsius: Self.colourTemperature(reading, config: config)).hex
            )
        )

        // The temperature, with its scale named: a picker chooses it now, so
        // a bare number is the reading a person misreads as the other scale.
        let top = Self.degrees(reading.temperature, units: config.units)
        let hasBand = config.showsHumidity || config.showsFeelsLike
        let scale = 2
        let topWidth = top.unicodeScalars.count * 4 * scale - scale
        canvas.drawText(
            top,
            at: PixelPoint(
                x: (PixelCanvas.width - topWidth) / 2,
                y: hasBand ? 1 : (PixelCanvas.height - 5 * scale) / 2
            ),
            ink: ink,
            scale: scale
        )

        // The small band, scale 1: humidity at the left edge, the felt
        // temperature at the right. Each present only when the tile says so —
        // a reading that carries no humidity draws the temperature alone even
        // when the tile asks for it.
        let secondary = Pixel.white
        if config.showsHumidity, let humidity = reading.relativeHumidity {
            canvas.drawText(
                "H\(Int(humidity.rounded()))%",
                at: PixelPoint(x: 1, y: 11),
                ink: secondary
            )
        }
        if config.showsFeelsLike {
            // A tilde, not the word. "feels 18°" was thirty-five of the
            // band's fifty-two pixels: it left one black column beside
            // "H78%", and at "feels -12°" it drew over the humidity. "~18°"
            // is fifteen, and a tilde before a temperature already reads as
            // "about this much" on every weather face that has room for less.
            let line = "~\(Int(Self.fahrenheitOrCelsius(felt, units: config.units).rounded()))°"
            let width = line.unicodeScalars.count * 4 - 1
            canvas.drawText(
                line,
                at: PixelPoint(x: PixelCanvas.width - width - 1, y: 11),
                ink: secondary
            )
        }
        return canvas
    }

    /// The temperature the digits are coloured from: what it feels like when
    /// the tile's Feels-like colour is on (the air when the reading carries
    /// no felt value), the air when it is off.
    ///
    /// Its own setting, apart from the felt LINE's `showsFeelsLike`: the
    /// TC002 face reads the same switch, so one switch means one thing on
    /// both clocks — where the colour used to follow whether the line showed.
    static func colourTemperature(_ reading: WeatherReading, config: WeatherTileConfig) -> Double {
        config.feelsLikeColour ? reading.apparentTemperature ?? reading.temperature : reading.temperature
    }

    private static func fahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    /// The value the scale's own letter names, for the small band's felt line.
    private static func fahrenheitOrCelsius(
        _ celsius: Double, units: WeatherTileConfig.Units
    ) -> Double {
        switch units {
        case .celsius: celsius
        case .fahrenheit: fahrenheit(celsius)
        }
    }
}
