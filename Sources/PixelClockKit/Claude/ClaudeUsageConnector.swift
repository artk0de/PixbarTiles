import Foundation

/// Where a source of Claude usage readings comes from.
///
/// A protocol rather than the file read itself, so the drawing can be tested
/// against a figure, and where the figure comes from is answered once, in the
/// type that implements it — `StatusLineClaudeUsageReporter` in this kit.
public protocol ClaudeUsageReporting: Sendable {
    /// The current reading, or nil when there is none to be had: no status-line
    /// document yet, or a week that has reset since the last one.
    func read() async throws -> ClaudeUsageReading?
}

/// How much of the Claude coding plan is gone, as an app in the clock's own
/// loop.
///
/// A `CodeUsage` tile: everything a reader sees — both pages, the ramp, the
/// reset spellings, the parameters the tile offers — is the substrate's, and
/// this type supplies the three things that are Claude's own. Its source, its
/// `Vendor`, and how a status-line document becomes a `CodeUsage.Reading`.
///
/// Compare `ZaiUsageConnector`: the two files differ in the source they read
/// and in nothing else. That is the property this shape exists to make
/// checkable — a divergence between the two tiles now has to be WRITTEN into
/// one of them rather than accumulated by neglect.
public struct ClaudeUsageConnector: Connector {
    /// The mark and the colours — the whole of what makes this tile Claude's.
    public static let vendor = CodeUsage.Vendor.claude

    /// The name this app lives under in the device's loop. One name, so a poll
    /// replaces the previous reading rather than growing a rotation.
    public static let appName = vendor.id

    /// Named from the type the way `VPNConnector` is: the panel's saves and
    /// the Add tile menu speak of the connector without an instance in hand.
    public static let id = vendor.id
    public var id: String { Self.id }
    public var displayName: String { Self.vendor.displayName }

    /// One minute: a subscription's remaining limit is watched, not glanced
    /// at, and a person who has just spent some of one wants the bar to move
    /// now rather than at the top of the next five minutes. Read against
    /// `CodeUsage.Tile.lifetime`, which is chosen for it.
    public let defaultInterval: TimeInterval = 60

    /// Ten seconds up to four hours — see `RefreshScale.codingSubscription`.
    public let refreshSteps = RefreshScale.codingSubscription
    public var defaultPolicy: TilePolicy { TileDefaults.codeUsage }
    public let isAudible = false
    public let isAmbient = true

    private let reporter: any ClaudeUsageReporting
    /// The tile's parameters, read at draw time: a picker moved in the tile's
    /// window reaches the next poll, not the next launch.
    private let parameters: @Sendable () -> CodeUsage.Parameters
    /// The zone reset times are said in: the Mac's, asked at draw time, so a
    /// Mac that travels says the new hour at the next poll.
    private let timeZone: @Sendable () -> TimeZone

    public init(
        reporter: any ClaudeUsageReporting,
        parameters: @escaping @Sendable () -> CodeUsage.Parameters = { .standard },
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.reporter = reporter
        self.parameters = parameters
        self.timeZone = timeZone
    }

    /// The reporter's reading, or the reason there is none. Whether the tile
    /// may run at all is its policy's answer, not this connector's.
    public func read() async throws -> ClaudeUsageReading {
        guard let reading = try await reporter.read() else { throw Failure.noReading }
        return reading
    }

    public var awtrixFace: AwtrixFace<ClaudeUsageReading> {
        AwtrixFace { Self.output(for: $0) }
    }

    public var ulanziFace: UlanziFace<ClaudeUsageReading>? {
        UlanziFace { [parameters, timeZone] in
            Self.ulanziOutput(for: $0, parameters: parameters(), timeZone: timeZone())
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Nothing to draw. Deliberately an error rather than an output saying
        /// "—": the app carries a `lifetime`, so a run that delivers nothing
        /// lets the clock drop the app by itself, which says the true thing
        /// — nothing here knows the figure any more — without inventing one.
        case noReading
    }

    /// The run the session drives. A reading that names no window at all is no
    /// delivery, so the tile leaves the clock until a figure returns. Faces
    /// cannot say this — they are total functions — so the run, the one place
    /// read and face meet, says it for them.
    public func produce() async throws -> AwtrixDelivery {
        guard let delivery = CodeUsage.Tile.awtrix(Self.reading(for: try await read()), vendor: Self.vendor)
        else { throw Failure.noReading }
        return delivery
    }

    /// What a status-line document says, in the shape the tile draws.
    ///
    /// The weekly figure is the reading's own `utilization`, dated by its
    /// `resetsAt`. `contextWindow` is deliberately not a window here: it is how
    /// full one session's context is, which empties on every `/clear` and is
    /// not an allowance anybody budgets against.
    static func reading(for reading: ClaudeUsageReading) -> CodeUsage.Reading {
        CodeUsage.Reading(
            fiveHour: reading.fiveHour.map {
                CodeUsage.Window(percent: $0.utilization, resetsAt: $0.resetsAt)
            },
            weekly: CodeUsage.Window(percent: reading.utilization, resetsAt: reading.resetsAt)
        )
    }

    /// What a reading looks like on the matrix.
    public static func output(for reading: ClaudeUsageReading) -> AwtrixDelivery {
        // The face is a total function, and a Claude reading always carries a
        // weekly figure, so this cannot be nil. `produce()` is where a source
        // that knows nothing turns into no delivery at all.
        CodeUsage.Tile.awtrix(Self.reading(for: reading), vendor: vendor)
            ?? AwtrixDelivery(text: appName, color: vendor.brand, surface: .app(appName))
    }

    /// What a reading looks like on the TC002's 52×16 panel.
    static func ulanziOutput(
        for reading: ClaudeUsageReading, parameters: CodeUsage.Parameters, timeZone: TimeZone
    ) -> UlanziDelivery {
        CodeUsage.Tile.ulanzi(
            Self.reading(for: reading), vendor: vendor,
            parameters: parameters, timeZone: timeZone
        )
    }
}
