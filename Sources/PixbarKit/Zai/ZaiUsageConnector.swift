import Foundation

/// How much of the z.ai coding plan is gone, as an app in the clock's own loop.
///
/// A `CodeUsage` tile, the same one `ClaudeUsageConnector` is: everything a
/// reader sees belongs to the substrate, and this type supplies the three
/// things that are z.ai's own — its source, its `Vendor`, and how a quota
/// answer becomes a `CodeUsage.Reading`.
public struct ZaiUsageConnector: Connector {
    /// The mark and the colours — the whole of what makes this tile z.ai's.
    public static let vendor = CodeUsage.Vendor.zai

    /// The name this app lives under in the device's loop. One name, so a poll
    /// replaces the previous reading rather than growing a rotation.
    public static let appName = vendor.id

    /// The connector's identifier — the tile key's connector half, and the
    /// keychain account's suffix. Written once on the vendor, read by the
    /// wiring and the derivation alike, so the three never drift.
    public static let connectorId = vendor.id

    public let id = ZaiUsageConnector.connectorId
    public var displayName: String { Self.vendor.displayName }

    /// One minute, the same cadence the Claude tile watches a plan at and for
    /// the same reason: a limit someone is spending is read, not glanced at.
    public let defaultInterval: TimeInterval = 60

    /// Ten seconds up to four hours — see `RefreshScale.codingSubscription`.
    public let refreshSteps = RefreshScale.codingSubscription
    public var defaultPolicy: TilePolicy { TileDefaults.codeUsage }
    public let isAudible = false
    public let isAmbient = true

    private let source: any ZaiUsageReporting
    /// The tile's parameters, read at draw time: a picker moved in the tile's
    /// window reaches the next poll, not the next launch.
    private let parameters: @Sendable () -> CodeUsage.Parameters
    /// The zone reset times are said in — the Mac's, never the server's
    /// Asia/Shanghai — asked at draw time.
    private let timeZone: @Sendable () -> TimeZone

    public init(
        source: any ZaiUsageReporting,
        parameters: @escaping @Sendable () -> CodeUsage.Parameters = { .standard },
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.source = source
        self.parameters = parameters
        self.timeZone = timeZone
    }

    /// The source's reading, or the reason there is none. Whether the tile may
    /// run at all is its policy's answer, not this connector's.
    public func read() async throws -> ZaiUsageReading {
        guard let reading = try await source.read() else { throw Failure.noReading }
        return reading
    }

    public var awtrixFace: AwtrixFace<ZaiUsageReading> {
        AwtrixFace { Self.output(for: $0) }
    }

    public var ulanziFace: UlanziFace<ZaiUsageReading>? {
        UlanziFace { [parameters, timeZone] in
            Self.ulanziOutput(for: $0, parameters: parameters(), timeZone: timeZone())
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Nothing to draw. Deliberately an error rather than an output saying
        /// "—": the app carries a `lifetime`, so a run that delivers nothing
        /// lets the clock drop the app by itself — the true thing, that this
        /// app knows no figure any more, without inventing one.
        case noReading
    }

    /// The run the session drives. A quota answer that placed no window is no
    /// delivery, so the tile leaves the clock until one comes back.
    public func produce() async throws -> AwtrixDelivery {
        guard let delivery = CodeUsage.Tile.awtrix(Self.reading(for: try await read()), vendor: Self.vendor)
        else { throw Failure.noReading }
        return delivery
    }

    /// What the quota route said, in the shape the tile draws.
    ///
    /// The MCP month is deliberately dropped: it meters tool calls against a
    /// monthly cap, which is neither of the two windows a coding plan is spent
    /// through, and a page that mixed it in would be comparing two different
    /// kinds of allowance side by side.
    static func reading(for reading: ZaiUsageReading) -> CodeUsage.Reading {
        CodeUsage.Reading(
            fiveHour: reading.fiveHour.map(Self.window),
            weekly: reading.weekly.map(Self.window)
        )
    }

    /// What a reading looks like on the matrix.
    ///
    /// The substrate's page — a figure, the mark and the band's bar. It used to
    /// be this tile's own: the windows joined into one line, `"84% 52%"`, with
    /// no mark and no bar. Two figures side by side made the reader do the
    /// comparing, and the one they wanted was always the week.
    public static func output(for reading: ZaiUsageReading) -> AwtrixDelivery {
        CodeUsage.Tile.awtrix(Self.reading(for: reading), vendor: vendor)
            ?? AwtrixDelivery(text: appName, color: vendor.brand, surface: .app(appName))
    }

    /// What a reading looks like on the TC002's panel.
    static func ulanziOutput(
        for reading: ZaiUsageReading, parameters: CodeUsage.Parameters, timeZone: TimeZone
    ) -> UlanziDelivery {
        CodeUsage.Tile.ulanzi(
            Self.reading(for: reading), vendor: vendor,
            parameters: parameters, timeZone: timeZone
        )
    }

    private static func window(_ window: ZaiUsageWindow) -> CodeUsage.Window {
        CodeUsage.Window(percent: window.percentUsed, resetsAt: window.resetsAt)
    }
}
