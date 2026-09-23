import Foundation

/// Where a source of weekly-allowance readings comes from.
///
/// A protocol rather than the file read itself, so the drawing can be tested
/// against a figure, and where the figure comes from is answered once, in the
/// type that implements it — `StatusLineClaudeUsageReporter` in this kit.
public protocol ClaudeUsageReporting: Sendable {
    /// The current weekly reading, or nil when there is none to be had: no
    /// status-line document yet, or a week that has reset since the last one.
    func read() async throws -> ClaudeUsageReading?
}

/// How much of this week's Claude allowance is gone, as an app in the clock's
/// own loop.
///
/// An app rather than a notification, for the same reason the weather is one: a
/// figure that is true all week is something you glance at, not something that
/// interrupts you. It says nothing out loud and has nothing to trigger by hand
/// — asking the service early answers the same percentage — so it is ambient
/// and silent, exactly like the weather.
public struct ClaudeUsageConnector: Connector {
    /// The name this app lives under in the device's loop. One name, so a poll
    /// replaces the previous reading rather than growing a rotation.
    public static let appName = "claude"

    /// Named from the type the way `VPNConnector` is: the panel's saves and
    /// the Add tile menu speak of the connector without an instance in hand.
    public static let id = "claude"
    public var id: String { Self.id }
    public let displayName = "Claude usage"
    /// One minute: a subscription's remaining limit is watched, not glanced
    /// at, and a person who has just spent some of one wants the bar to move
    /// now rather than at the top of the next five minutes.
    ///
    /// Still read against `lifetime`, which is the quarter hour below. Fifteen
    /// polls inside one lifetime is the same insurance five minutes bought
    /// three of: a crashed Mac clears the figure within the quarter hour, and
    /// the app still LEAVES the clock soon after a Focus does.
    public let defaultInterval: TimeInterval = 60

    /// Ten seconds up to four hours — see `RefreshScale.codingSubscription`.
    public let refreshSteps = RefreshScale.codingSubscription
    public var defaultPolicy: TilePolicy { TileDefaults.claude }
    public let narrator: Voice = .crystal
    public let isAudible = false
    public let isAmbient = true

    private let reporter: any ClaudeUsageReporting
    /// Which figure the tile shows. Read at draw time rather than held, so a
    /// metric picked in the tile detail takes effect at the next poll instead
    /// of at the next launch — the reason `WeatherConnector` reads its place
    /// the same way.
    private let metric: @Sendable () -> ClaudeDisplayMetric
    /// The TC002 face's two settings, read at draw time for the same reason
    /// the metric is.
    private let usageFace: @Sendable () -> UsageFaceConfig
    /// The zone reset times are said in: the Mac's, asked at draw time, so a
    /// Mac that travels says the new hour at the next poll.
    private let timeZone: @Sendable () -> TimeZone

    public init(
        reporter: any ClaudeUsageReporting,
        metric: @escaping @Sendable () -> ClaudeDisplayMetric = { .weekly },
        usageFace: @escaping @Sendable () -> UsageFaceConfig = { .standard },
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.reporter = reporter
        self.metric = metric
        self.usageFace = usageFace
        self.timeZone = timeZone
    }

    /// The reporter's reading, or the reason there is none. Whether the tile
    /// may run at all is its policy's answer, not this connector's.
    public func read() async throws -> ClaudeUsageReading {
        guard let reading = try await reporter.read() else { throw Failure.noReading }
        return reading
    }

    public var awtrixFace: AwtrixFace<ClaudeUsageReading> {
        AwtrixFace { reading in
            Self.output(for: reading, metric: metric()) ?? Self.output(for: reading)
        }
    }

    public var ulanziFace: UlanziFace<ClaudeUsageReading>? {
        UlanziFace { [usageFace, timeZone] in
            Self.ulanziOutput(for: $0, config: usageFace(), timeZone: timeZone())
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Nothing to draw. Deliberately an error rather than an output saying
        /// "—": the app carries a `lifetime`, so a run that delivers nothing
        /// lets the clock drop the app by itself, which says the true thing
        /// — nothing here knows the figure any more — without inventing one.
        case noReading
    }

    /// The run the session drives, and where the metric's gate lives: a chosen
    /// figure the reading does not carry is no delivery at all, so the tile
    /// leaves the clock until its figure returns. Faces cannot say this — they
    /// are total functions — so the run, the one place read and face meet,
    /// says it for them.
    public func produce() async throws -> AwtrixDelivery {
        let reading = try await read()
        guard let delivery = Self.output(for: reading, metric: metric()) else {
            throw Failure.noReading
        }
        return delivery
    }

    /// What a reading looks like on the matrix, for the metric the tile shows.
    ///
    /// Three faces, one per metric. The weekly one is the face this connector
    /// always drew; the other two draw the same bar around their own figure.
    /// Nil when the metric's figure is missing from the reading — `produce()`
    /// is the caller that turns that into no delivery, and the
    /// `awtrixFace`'s fallback to the weekly figure exists only for the
    /// protocol's total form, which a gated run never reaches.
    public static func output(
        for reading: ClaudeUsageReading, metric: ClaudeDisplayMetric
    ) -> AwtrixDelivery? {
        guard let figure = metric.percentage(in: reading) else { return nil }
        return usageBar(figure)
    }

    /// What the weekly reading looks like on the matrix — the face as it was
    /// before there was a choice, kept because the drawing tests and the
    /// default tile both read it.
    ///
    /// Separated from `read()` so the drawing can be tested against a figure
    /// rather than against a network. Everything decided here is decided from
    /// the one number.
    public static func output(for reading: ClaudeUsageReading) -> AwtrixDelivery {
        usageBar(reading.utilization)
    }

    /// One percentage as the tile draws it: the true figure — including one
    /// past a hundred — beside the star, over the band's own bar.
    private static func usageBar(_ percentage: Int) -> AwtrixDelivery {
        AwtrixDelivery(
            // The true figure, including one past a hundred. The bar clamps
            // because the firmware has nowhere to draw the rest; the text has
            // no such excuse, and hiding an overage from the reader is not the
            // same problem as fitting one on eight rows.
            text: "\(percentage)%",
            icon: .bundled("ClaudeStar"),
            progress: ProgressBar(
                percent: percentage,
                fill: UsageBand(utilization: percentage).fillColour,
                track: Self.trackColour
            ),
            color: ClaudeUsage.brandColour,
            surface: .app(Self.appName),
            // A quarter of an hour, and it is doing two jobs. The usual one is
            // insurance: a crashed Mac stops refreshing and the clock clears a
            // figure nothing is standing behind any more. The second is how
            // this app LEAVES when the Focus changes — nothing retracts it, the
            // gate simply stops feeding it and the lifetime finishes the job.
            // Read with `defaultInterval`, which is chosen against this.
            lifetime: 900
        )
    }

    /// The unfilled part of the bar. Dark enough to read as empty at brightness
    /// two, light enough that the bar's full width is still visible — an unlit
    /// track makes a half-full bar look like a short one.
    static let trackColour = "#303030"

    /// What a reading looks like on the TC002's 52×16 panel: the shared usage
    /// face, the five-hour window on the session row and the seven-day figure
    /// — the reading's own — on the weekly row. The metric answers the AWTRIX
    /// page alone; the TC002 draws both windows at once, and a window the
    /// document did not carry is a row with no reading, never a zero.
    static func ulanziOutput(
        for reading: ClaudeUsageReading, config: UsageFaceConfig, timeZone: TimeZone
    ) -> UlanziDelivery {
        UsageFace.delivery(
            vendor: .claude,
            session: reading.fiveHour.map {
                UsageFace.Window(percent: $0.utilization, resetsAt: $0.resetsAt)
            },
            weekly: UsageFace.Window(percent: reading.utilization, resetsAt: reading.resetsAt),
            config: config,
            timeZone: timeZone
        )
    }
}
