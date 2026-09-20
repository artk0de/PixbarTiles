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
    public var defaultPolicy: TilePolicy { TileDefaults.claude }
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

    /// The reporter's reading, or the reason there is none.
    public func read() async throws -> ClaudeUsageReading {
        // The gate first, so a poll outside working hours costs no request.
        guard showsNow() else { throw Failure.outOfFocus }
        guard let reading = try await reporter.read() else { throw Failure.noReading }
        return reading
    }

    public var awtrixFace: AwtrixFace<ClaudeUsageReading> {
        AwtrixFace { Self.output(for: $0) }
    }

    public var ulanziFace: UlanziFace<ClaudeUsageReading>? {
        UlanziFace { Self.ulanziOutput(for: $0) }
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
    /// Separated from `read()` so the drawing can be tested against a figure
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

    /// The bundled star as the TC002 image layer, measured from the file it
    /// ships as: 8×8 and 8 frames, inside every measured image limit (A4).
    static let star = UlanziImage(
        base64: (BundledIcon.data(named: "ClaudeStar") ?? Data()).base64EncodedString(),
        isAnimated: true,
        frameCount: 8,
        pixelSize: (width: 8, height: 8)
    )

    /// What a reading looks like on the TC002's 52×16 panel: the percentage
    /// rastered through the 3×5 font at scale 2 in the brand colour, the star
    /// riding beside it as the image layer.
    static func ulanziOutput(for reading: ClaudeUsageReading) -> UlanziDelivery {
        var canvas = PixelCanvas()
        let text = "\(reading.utilization)%"
        let ink = UlanziColour(hex: ClaudeUsage.brandColour)
        let width = text.unicodeScalars.count * 4 * 2 - 2
        canvas.drawText(
            text,
            at: PixelPoint(
                x: (PixelCanvas.width - width) / 2, y: (PixelCanvas.height - 10) / 2
            ),
            ink: Pixel(colour: ink),
            scale: 2
        )
        return UlanziDelivery(
            scene: UlanziScene(
                frames: [
                    UlanziFrame(duration: 5, draw: [canvas.drawCommands()], image: [star])
                ]
            )
        )
    }
}
