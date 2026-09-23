// Tests/PixelClockKitTests/ClaudeUsageConnectorTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The TC002 face of the Claude usage connector: the shared usage face
// (`UsageFace`) fed the five-hour and the seven-day windows, whatever the
// tile's metric picks. The AWTRIX half is the metric's own; its tests live
// beside the other faces in ConnectorFaceTests.

@Suite struct ClaudeTC002FaceTests {
    func makeConnector() -> ClaudeUsageConnector {
        ClaudeUsageConnector(reporter: Reports(reading: nil))
    }

    /// Answers with one fixed reading; the face is tested against a reading,
    /// never against the network.
    private struct Reports: ClaudeUsageReporting {
        let reading: ClaudeUsageReading?
        func read() async throws -> ClaudeUsageReading? { reading }
    }

    /// One reading carrying every window.
    private let reading = ClaudeUsageReading(
        utilization: 41,
        resetsAt: nil,
        fiveHour: ClaudeUsageWindow(utilization: 23, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
        contextWindow: 8,
        observedAt: nil
    )

    private let utc = TimeZone(identifier: "UTC")!

    // The page is the shared usage face: the five-hour window on the session
    // row, the seven-day figure — the reading's own — on the weekly row, each
    // with its own reset instant. The metric answers only the AWTRIX page.
    @Test func thePageIsTheSharedUsageFaceFedBothWindows() {
        let config = UsageFaceConfig(resetEvery: 30, resetAfter: 20)
        let weekly = ClaudeUsageReading(
            utilization: 41,
            resetsAt: Date(timeIntervalSince1970: 1_790_845_200),
            fiveHour: reading.fiveHour,
            contextWindow: 8
        )

        #expect(
            ClaudeUsageConnector.ulanziOutput(for: weekly, config: config, timeZone: utc)
                == UsageFace.delivery(
                    vendor: .claude,
                    session: UsageFace.Window(percent: 23, resetsAt: reading.fiveHour?.resetsAt),
                    weekly: UsageFace.Window(
                        percent: 41, resetsAt: Date(timeIntervalSince1970: 1_790_845_200)
                    ),
                    config: config,
                    timeZone: utc
                )
        )
    }

    // A five-hour window the document did not carry is a row with no reading
    // — the face's `--` over an empty bar, never a zero.
    @Test func aMissingFiveHourWindowIsARowWithNoReading() {
        let bare = ClaudeUsageReading(utilization: 41, resetsAt: nil)

        #expect(
            ClaudeUsageConnector.ulanziOutput(for: bare, config: .standard, timeZone: utc)
                == UsageFace.delivery(
                    vendor: .claude,
                    session: nil,
                    weekly: UsageFace.Window(percent: 41, resetsAt: nil),
                    config: .standard,
                    timeZone: utc
                )
        )
    }

    // The tile's two settings and the zone are read when the face draws, not
    // when the connector is built: a picker moved in the tile's window
    // reaches the next poll.
    @Test func theFaceReadsTheTilesSettingsWhenItDraws() throws {
        let config = UsageFaceConfig(resetEvery: 60, resetAfter: 20)
        let connector = ClaudeUsageConnector(
            reporter: Reports(reading: nil),
            usageFace: { config },
            timeZone: { TimeZone(identifier: "UTC")! }
        )

        let delivery = try #require(connector.ulanziFace?.draw(reading))

        #expect(
            delivery == ClaudeUsageConnector.ulanziOutput(for: reading, config: config, timeZone: utc)
        )
    }

    // And the whole page ships as one image — the GIF at the panel's origin —
    // inside every measured limit.
    @Test func thePageShipsAsOneImageInsideTheLimits() throws {
        let connector = makeConnector()
        let delivery = try #require(connector.ulanziFace?.draw(reading))
        let frame = delivery.scene.frames[0]

        #expect(delivery.scene.frames.count == 1)
        #expect(frame.draw.isEmpty)
        #expect(frame.image.count == 1)
        #expect((try UlanziScene(frames: [frame]).jsonObject()).isEmpty == false)
    }
}
