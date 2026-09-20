// Tests/PixelClockKitTests/ClaudeUsageConnectorTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The TC002 face of the Claude usage connector: the shared three-row usage
// face fed all three windows at once — daily, weekly, session — whatever the
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

    /// One reading carrying all three windows, for the rows to pick from.
    private let reading = ClaudeUsageReading(
        utilization: 41,
        resetsAt: nil,
        fiveHour: ClaudeUsageWindow(utilization: 23, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
        contextWindow: 8,
        observedAt: nil
    )

    // The page carries all three figures in the order the tile detail names
    // them — the metric answers only the AWTRIX page, and the TC002 ignores it.
    @Test func thePageCarriesAllThreeRowsWhateverTheMetricChooses() {
        let rows = ClaudeUsageConnector.rows(for: reading)

        #expect(rows.map(\.label) == ["DAY", "WK", "SES"])
        #expect(rows.map(\.value) == ["23%", "41%", "8%"])
    }

    // A window the document did not carry is a dash, not a zero: nothing here
    // knows that figure, and a dash says so at a glance.
    @Test func aMissingWindowIsADash() {
        let bare = ClaudeUsageReading(utilization: 41, resetsAt: nil)

        let rows = ClaudeUsageConnector.rows(for: bare)

        #expect(rows.map(\.value) == ["-", "41%", "-"])
    }

    // Each value inks in its own band's colour — the weekly 41% in the brand's
    // orange, a missing figure in the empty bar's track — so the page reads as
    // three figures, not one warning.
    @Test func everyValueInksInItsOwnBand() {
        let rows = ClaudeUsageConnector.rows(for: reading)

        #expect(rows[0].colour == UlanziColour(hex: ClaudeUsageBand(utilization: 23).fillColour))
        #expect(rows[1].colour == UlanziColour(hex: ClaudeUsage.brandColour))
        #expect(rows[2].colour == UlanziColour(hex: ClaudeUsageBand(utilization: 8).fillColour))
        #expect(
            ClaudeUsageConnector.rows(for: ClaudeUsageReading(utilization: 41, resetsAt: nil))[0].colour
                == UlanziColour(hex: ClaudeUsageConnector.trackColour)
        )
    }

    // And the whole page ships as the one bitmap, with no image beside it —
    // the star's place on this panel was taken by the rows.
    @Test func thePageShipsAsOneBitmapWithNoImage() throws {
        let connector = makeConnector()
        let delivery = try #require(connector.ulanziFace?.draw(reading))
        let frame = delivery.scene.frames[0]

        #expect(delivery.scene.frames.count == 1)
        #expect(frame.draw.count == 1)   // the single db (D2)
        #expect(frame.image.isEmpty)
        guard case .bitmap = try #require(frame.draw.first) else {
            Issue.record("not a bitmap")
            return
        }
        // Declared metadata sits inside every measured limit (A4), so the
        // scene the face builds always encodes.
        #expect((try UlanziScene(frames: [frame]).jsonObject()).isEmpty == false)
    }
}
