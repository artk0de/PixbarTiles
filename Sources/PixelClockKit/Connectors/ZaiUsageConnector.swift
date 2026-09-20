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

    /// What a reading looks like on the matrix: the figures in a row, in the
    /// order the plan names them, the windows the quota route did not name
    /// leaving no figure behind. The shared three-row face has no AWTRIX
    /// counterpart — its layout is the TC002 panel's — so the AWTRIX page
    /// carries the metrics as one line.
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

    /// What a reading looks like on the TC002's panel: the shared three-row
    /// usage face fed the plan's windows in the order the plan names them —
    /// five hours, week, MCP month. A window the quota route did not name is
    /// a dash, never a zero, and it keeps its band: the page's shape does not
    /// depend on what the route felt like saying today.
    static func ulanziOutput(for reading: ZaiUsageReading) -> UlanziDelivery {
        UlanziDelivery(
            scene: UlanziScene(
                frames: [
                    UlanziFrame(duration: 5, draw: [UsageRows.drawCommands(rows(for: reading))])
                ]
            )
        )
    }

    /// The page's three rows, in the order the plan names them. The values are
    /// inked in the plan's own blue; the dash a missing window leaves is in
    /// the layout's dim grey, which is what an absent figure is drawn in
    /// anywhere on the panel.
    static func rows(for reading: ZaiUsageReading) -> [UsageRows.Row] {
        [
            row("DAY", reading.fiveHour),
            row("WK", reading.weekly),
            row("MCP", reading.mcpMonthly),
        ]
    }

    /// One band from a window that may not be there: the percent as text, in
    /// the plan's colour, or the dash in the layout's own grey.
    private static func row(_ label: String, _ window: ZaiUsageWindow?) -> UsageRows.Row {
        UsageRows.Row(
            label: label,
            value: window.map { "\($0.percentUsed)%" } ?? "-",
            colour: window != nil
                ? UlanziColour(hex: ZaiUsage.brandColour)
                : UsageRows.labelColour
        )
    }
}
