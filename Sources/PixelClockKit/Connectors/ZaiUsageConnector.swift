import Foundation

/// How much of the z.ai coding plan is gone: the plan's windows beside what
/// the period spent, as an app in the clock's own loop.
///
/// Ambient and silent, exactly like the weather and the Claude figure: a
/// reading that is true until the next poll is something you glance at, not
/// something that interrupts, and it says nothing out loud and has nothing to
/// trigger — asking the dashboard early answers the same numbers.
public struct ZaiUsageConnector: Connector {
    /// The name this app lives under in the device's loop. One name, so a poll
    /// replaces the previous reading rather than growing a rotation.
    public static let appName = "zai"

    /// The connector's identifier — the tile key's connector half, and the
    /// keychain account's suffix. Written once here, read by the wiring and
    /// the derivation alike, so the three never drift.
    public static let connectorId = appName

    public let id = ZaiUsageConnector.connectorId
    public let displayName = "z.ai usage"
    /// Ten minutes, and chosen against `lifetime` rather than on its own: the
    /// figure moves slowly, but the app must leave the clock soon after a
    /// Focus does, and the lifetime is the only thing that removes it. Three
    /// polls inside one lifetime — the same insurance the Claude figure buys.
    public let defaultInterval: TimeInterval = 600
    public var defaultPolicy: TilePolicy { TileDefaults.zai }
    public let isAudible = false
    public let isAmbient = true

    private let source: any ZaiUsageReporting

    public init(source: any ZaiUsageReporting) {
        self.source = source
    }

    /// The source's reading, or the reason there is none. Whether the tile
    /// may run at all is its policy's answer, not this connector's.
    public func read() async throws -> ZaiUsageReading {
        guard let reading = try await source.read() else { throw Failure.noReading }
        return reading
    }

    public var awtrixFace: AwtrixFace<ZaiUsageReading> {
        AwtrixFace { Self.output(for: $0) }
    }

    public var ulanziFace: UlanziFace<ZaiUsageReading>? {
        UlanziFace { Self.ulanziOutput(for: $0) }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Nothing to draw. Deliberately an error rather than an output saying
        /// "—": the app carries a `lifetime`, so a run that delivers nothing
        /// lets the clock drop the app by itself — the true thing, that this
        /// app knows no figure any more, without inventing one.
        case noReading
    }

    /// PHASE 6C CALL SITE — the shared three-row usage face.
    ///
    /// The design gives this connector the shared three-row usage layout on
    /// both models, the component the Claude TC002 face uses; it lands with
    /// the phase 6c merge. Until then this function is the ONLY place this
    /// connector draws an AWTRIX output, and wiring the shared face in must be
    /// a swap of this one body — nothing above it reads the drawing.
    ///
    /// Provisionally the figures stand in a row in the order the plan names
    /// them, five hours, week, MCP month, the windows the quota route did not
    /// name leaving no figure behind.
    public static func output(for reading: ZaiUsageReading) -> AwtrixDelivery {
        let rows = reading.usageRows
        return AwtrixDelivery(
            text: rows.isEmpty ? Self.appName : rows.map { "\($0.percentUsed)%" }.joined(separator: " "),
            color: ZaiUsage.brandColour,
            surface: .app(Self.appName),
            // Half an hour: three polls inside one lifetime survives a couple
            // of misses while still clearing the matrix within the half hour.
            // Read with `defaultInterval`, which is chosen against this.
            lifetime: 1_800
        )
    }

    /// PHASE 6C CALL SITE — see `output(for:)`; this is its TC002 half.
    ///
    /// Provisionally the three rows are rastered through the 3×5 font, one
    /// figure per row, in the plan's order. The row order carries the meaning:
    /// the font holds digits and the percent sign and nothing else (D12), so
    /// there are no labels to spell.
    public static func ulanziOutput(for reading: ZaiUsageReading) -> UlanziDelivery {
        var canvas = PixelCanvas()
        let ink = Pixel(colour: UlanziColour(hex: ZaiUsage.brandColour))
        let rows = reading.usageRows
        // Five rows of glyphs, then a one-row gap, sits three times in the
        // sixteen the panel holds: 0–4, 6–10, 11–15.
        let tops = [0, 6, 11]
        for (index, row) in rows.enumerated() where index < tops.count {
            let text = "\(row.percentUsed)%"
            let width = text.unicodeScalars.count * 4 - 1
            canvas.drawText(
                text,
                at: PixelPoint(x: (PixelCanvas.width - width) / 2, y: tops[index]),
                ink: ink
            )
        }
        return UlanziDelivery(
            scene: UlanziScene(
                frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])]
            )
        )
    }
}
