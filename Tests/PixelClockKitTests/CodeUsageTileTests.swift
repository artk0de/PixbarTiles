import Foundation
import Testing
@testable import PixelClockKit

// The template chooses the page. Both vendors reach the panel through
// `CodeUsage.Tile.ulanzi`, so the layout a tile is set to — and, on the Circle,
// which windows it was told to show — has to arrive THERE, or the setting is a
// picker that moves and changes nothing.

private let instant = Date(timeIntervalSince1970: 1_790_240_700)
private let both = CodeUsage.Reading(
    fiveHour: CodeUsage.Window(percent: 84, resetsAt: instant),
    weekly: CodeUsage.Window(percent: 52, resetsAt: instant)
)
private let utc = TimeZone(identifier: "UTC")!

/// How many pictures the page the clock is handed actually plays.
private func playedFrames(_ delivery: UlanziDelivery) -> Int {
    delivery.scene.frames.first?.image.first?.frameCount ?? 0
}

private func page(_ parameters: CodeUsage.Parameters) -> UlanziDelivery {
    CodeUsage.Tile.ulanzi(both, vendor: .claude, parameters: parameters, timeZone: utc)
}

@Suite struct CodeUsageTileLayoutTests {
    // Compact is what every existing tile is set to, and it has to keep
    // drawing exactly what it drew — the layout arriving is not licence for
    // the default page to change by a pixel.
    @Test func theCompactLayoutDrawsWhatItAlwaysDrew() {
        let parameters = CodeUsage.Parameters(resetEvery: 10, resetAfter: 80)

        #expect(page(parameters) == CodeUsage.Compact.delivery(
            vendor: .claude, session: both.fiveHour, weekly: both.weekly,
            config: parameters, timeZone: utc
        ))
    }

    @Test func theCircleLayoutDrawsTheCirclesOwnTimeline() {
        let parameters = CodeUsage.Parameters(
            resetEvery: 10, resetAfter: 80, layout: .circle, windows: CodeUsage.WindowKind.allCases
        )
        let expected = CodeUsage.Circle.timeline(
            vendor: .claude,
            windows: [(kind: .fiveHour, reading: both.fiveHour),
                      (kind: .weekly, reading: both.weekly)],
            parameters: parameters, timeZone: utc
        )

        #expect(playedFrames(page(parameters)) == expected.count)
        #expect(page(parameters) != page(CodeUsage.Parameters(resetEvery: 10, resetAfter: 80)))
    }

    // One window selected is one window drawn — the multi-select is what the
    // Circle rotates through, not a hint.
    @Test func theCircleShowsOnlyTheWindowsTheTileSelected() {
        let one = CodeUsage.Parameters(
            resetEvery: 10, resetAfter: 80, layout: .circle, windows: [.weekly]
        )
        let expected = CodeUsage.Circle.timeline(
            vendor: .claude, windows: [(kind: .weekly, reading: both.weekly)],
            parameters: one, timeZone: utc
        )

        #expect(playedFrames(page(one)) == expected.count)
        // With one window there is no change to make, so the page is shorter
        // than the two-window one by both sweeps.
        let two = CodeUsage.Parameters(
            resetEvery: 10, resetAfter: 80, layout: .circle, windows: CodeUsage.WindowKind.allCases
        )
        #expect(playedFrames(page(one)) < playedFrames(page(two)))
    }

    // A selected window the source never reported still takes its turn, drawn
    // as no reading — the page's shape is the tile's setting, not the route's
    // mood.
    @Test func aSelectedWindowWithNoReadingStillTakesItsTurn() {
        let parameters = CodeUsage.Parameters(
            resetEvery: 10, resetAfter: 80, layout: .circle, windows: CodeUsage.WindowKind.allCases
        )
        let sessionOnly = CodeUsage.Reading(fiveHour: both.fiveHour, weekly: nil)
        let drawn = CodeUsage.Tile.ulanzi(
            sessionOnly, vendor: .claude, parameters: parameters, timeZone: utc
        )

        #expect(playedFrames(drawn) == CodeUsage.Circle.timeline(
            vendor: .claude,
            windows: [(kind: .fiveHour, reading: both.fiveHour), (kind: .weekly, reading: nil)],
            parameters: parameters, timeZone: utc
        ).count)
    }

    // The reading answers for a window by NAME, so the face never has to know
    // which property holds which period.
    @Test func aReadingAnswersForTheWindowItIsAsked() {
        #expect(both.window(.fiveHour) == both.fiveHour)
        #expect(both.window(.weekly) == both.weekly)
        #expect(CodeUsage.Reading(fiveHour: nil, weekly: nil).window(.weekly) == nil)
    }
}
