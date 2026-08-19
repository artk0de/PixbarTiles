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
/// be remembered before it is written, belongs to `ConnectorHost` and
/// `DeviceCustody`.
public struct WeatherConnector: Connector {
    /// The name this app's reading lives under in the device's loop. One name,
    /// so a poll replaces the previous reading rather than adding to a rotation
    /// that grows all day.
    public static let appName = "weather"

    public let id = "weather"
    public let displayName = "Weather"
    /// The service's own cadence, so a user who never touches the slider polls
    /// a free public API at exactly the rate it updates.
    public let defaultInterval: TimeInterval = OpenMeteoSource.defaultInterval
    /// Nothing here is heard. The reading is drawn into the device's own loop
    /// and the sky is a setting on the matrix — no speech, no jingle, nothing
    /// that reaches the room. So the two quiet rules do not apply to it: a
    /// Focus and a busy microphone exist to stop the app SPEAKING, and holding
    /// this connector through the shipped nine-hour window froze the
    /// temperature on the clock until morning.
    public let isAudible = false

    private let source: OpenMeteoSource
    /// Read on every produce rather than held, so a location typed into the
    /// settings takes effect at the next poll instead of at the next launch.
    private let location: @Sendable () -> Coordinates

    public init(source: OpenMeteoSource, location: @escaping @Sendable () -> Coordinates) {
        self.source = source
        self.location = location
    }

    public func produce() async throws -> ConnectorOutput {
        let reading = try await source.reading(at: location())
        let theme = WeatherTheme(code: reading.code, isDay: reading.isDay)
        return ConnectorOutput(
            text: Self.degrees(reading.temperature),
            color: theme.colour,
            surface: .app(Self.appName),
            overlay: theme.overlay
        )
    }

    /// A temperature as eight pixels of height can show it.
    ///
    /// Whole degrees: the matrix is 32 by 8 and a decimal point costs two
    /// columns to say something nobody reads off a clock across a room.
    /// `rounded()` rather than truncation, so -3.6 is -4 rather than -3 — the
    /// wrong direction on the side of the scale where it matters.
    static func degrees(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }
}
