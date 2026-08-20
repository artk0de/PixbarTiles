import Foundation

/// Where a source of weekly-allowance readings comes from.
///
/// A protocol rather than the HTTP call itself, because the awkward part of
/// this connector is not drawing the number — it is that the credential belongs
/// to another program. Keeping the fetch behind this line lets the drawing be
/// tested without one, and lets the credential question be answered once, in
/// the type that implements it.
public protocol ClaudeUsageReporting: Sendable {
    /// The current weekly reading, or nil when the service cannot be asked —
    /// no credential, an expired one, or an answer that carried no weekly bar.
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

    public let id = "claude"
    public let displayName = "Claude usage"
    /// Ten minutes, matching the weather. The figure moves only when work is
    /// being done, and a weekly bar does not move fast enough to be worth
    /// asking about more often than that.
    public let defaultInterval: TimeInterval = 600
    public let narrator: Voice = .crystal
    public let isAudible = false
    public let isAmbient = true

    private let reporter: any ClaudeUsageReporting

    public init(reporter: any ClaudeUsageReporting) {
        self.reporter = reporter
    }

    public func produce() async throws -> ConnectorOutput {
        guard let reading = try await reporter.read() else { throw Failure.noReading }
        return Self.output(for: reading)
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Nothing to draw. Deliberately an error rather than an output saying
        /// "—": the app carries a `lifetime`, so a run that delivers nothing
        /// lets the clock drop the app by itself, which says the true thing
        /// — nothing here knows the figure any more — without inventing one.
        case noReading
    }

    /// What a reading looks like on the matrix.
    ///
    /// Separated from `produce` so the drawing can be tested against a figure
    /// rather than against a network. Everything decided here is decided from
    /// the one number.
    public static func output(for reading: ClaudeUsageReading) -> ConnectorOutput {
        ConnectorOutput(
            // The true figure, including one past a hundred. The bar clamps
            // because the firmware has nowhere to draw the rest; the text has
            // no such excuse, and hiding an overage from the reader is not the
            // same problem as fitting one on eight rows.
            text: "\(reading.utilization)%",
            icon: .bundled("ClaudeStar"),
            progress: ProgressBar(
                percent: reading.utilization,
                fill: ClaudeUsageBand(utilization: reading.utilization).fillColour,
                track: Self.trackColour
            ),
            color: ClaudeUsage.brandColour,
            surface: .app(Self.appName),
            // An hour, matching the weather: at a ten-minute poll six refreshes
            // fit inside it, so five consecutive failures are survivable before
            // the clock drops the app.
            lifetime: 3_600
        )
    }

    /// The unfilled part of the bar. Dark enough to read as empty at brightness
    /// two, light enough that the bar's full width is still visible — an unlit
    /// track makes a half-full bar look like a short one.
    static let trackColour = "#303030"
}
