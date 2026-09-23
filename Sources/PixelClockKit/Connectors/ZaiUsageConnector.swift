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
    /// The TC002 face's two settings, read at draw time: a picker moved in
    /// the tile's window reaches the next poll, not the next launch.
    private let usageFace: @Sendable () -> UsageFaceConfig
    /// The zone reset times are said in — the Mac's, never the server's
    /// Asia/Shanghai — asked at draw time.
    private let timeZone: @Sendable () -> TimeZone

    public init(
        source: any ZaiUsageReporting,
        usageFace: @escaping @Sendable () -> UsageFaceConfig = { .standard },
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.source = source
        self.usageFace = usageFace
        self.timeZone = timeZone
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
        UlanziFace { [usageFace, timeZone] in
            Self.ulanziOutput(for: $0, config: usageFace(), timeZone: timeZone())
        }
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
    /// leaving no figure behind. The shared usage face has no AWTRIX
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

    /// What a reading looks like on the TC002's panel: the shared usage face,
    /// the five-hour window on the session row and the week on the weekly
    /// row, each with the reset instant the quota route dated it with. A
    /// window the route did not name is a row with no reading, never a zero,
    /// and keeps its place: the page's shape does not depend on what the
    /// route felt like saying today. The MCP month has no row on this face.
    static func ulanziOutput(
        for reading: ZaiUsageReading, config: UsageFaceConfig, timeZone: TimeZone
    ) -> UlanziDelivery {
        UsageFace.delivery(
            vendor: .zai,
            session: reading.fiveHour.map(Self.window),
            weekly: reading.weekly.map(Self.window),
            config: config,
            timeZone: timeZone
        )
    }

    private static func window(_ window: ZaiUsageWindow) -> UsageFace.Window {
        UsageFace.Window(percent: window.percentUsed, resetsAt: window.resetsAt)
    }
}
