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
    /// Five minutes, and chosen against `lifetime` rather than on its own.
    ///
    /// The figure itself would tolerate a much lazier poll — a weekly bar moves
    /// slowly. What sets this is that the app must leave the clock soon after
    /// the Focus does, and the only thing that removes it is its lifetime
    /// expiring. Three polls inside one lifetime survives a couple of misses
    /// while still clearing the matrix within a quarter of an hour.
    public let defaultInterval: TimeInterval = 300
    public let narrator: Voice = .crystal
    public let isAudible = false
    public let isAmbient = true

    private let reporter: any ClaudeUsageReporting
    private let showsNow: @Sendable () -> Bool

    /// `showsNow` is how the Focus reaches a type that must not know what a
    /// Focus is. The default shows always, so a construction site with no
    /// opinion behaves as though there were no gate at all.
    public init(
        reporter: any ClaudeUsageReporting,
        showsNow: @escaping @Sendable () -> Bool = { true }
    ) {
        self.reporter = reporter
        self.showsNow = showsNow
    }

    public func produce() async throws -> AwtrixDelivery {
        // The gate first, so a poll outside working hours costs no request.
        guard showsNow() else { throw Failure.outOfFocus }
        guard let reading = try await reporter.read() else { throw Failure.noReading }
        return Self.output(for: reading)
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Nothing to draw. Deliberately an error rather than an output saying
        /// "—": the app carries a `lifetime`, so a run that delivers nothing
        /// lets the clock drop the app by itself, which says the true thing
        /// — nothing here knows the figure any more — without inventing one.
        case noReading
        /// This is not one of the hours this app belongs to. Same mechanism as
        /// `noReading` and a different reason, kept apart so a panel or a log
        /// can tell "cannot say" from "not now".
        case outOfFocus
    }

    /// What a reading looks like on the matrix.
    ///
    /// Separated from `produce` so the drawing can be tested against a figure
    /// rather than against a network. Everything decided here is decided from
    /// the one number.
    public static func output(for reading: ClaudeUsageReading) -> AwtrixDelivery {
        AwtrixDelivery(
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
}
