import Foundation
import Testing
@testable import PixelClockKit

// Circle: one window at a time, the reading unrolled around the panel's rim.
//
// The design was approved as the frames the `tc002-face-mockup` skill's
// `gen.py` computes. `Scripts/make_usage_face_oracle.py` records those frames
// into `usage_circle_oracle.json`; the Swift face is held to them pixel for
// pixel and delay for delay. A change of design starts in gen.py, is re-recorded
// there, and only then reaches Swift — never the other way round.

private struct CircleOracle: Decodable {
    struct Window: Decodable {
        let kind: String
        let percent: Int?
        let resetsAt: Double?
    }

    struct Frame: Decodable {
        let ms: Int
        let rows: [String]
    }

    struct Case: Decodable {
        let id: String
        let vendor: String
        let windows: [Window]
        let dwellMs: Int
        let resetAfter: Int
        let frames: [Frame]
    }

    let timeZone: String
    let width: Int
    let height: Int
    let cases: [Case]
}

private func loadCircleOracle() throws -> CircleOracle {
    let url = try #require(Bundle.module.url(
        forResource: "usage_circle_oracle", withExtension: "json"
    ))
    return try JSONDecoder().decode(CircleOracle.self, from: Data(contentsOf: url))
}

/// A canvas as the oracle spells it: sixteen rows of packed `rrggbb` hex.
private func circleHexRows(_ canvas: PixelCanvas) -> [String] {
    (0..<canvas.height).map { y in
        (0..<canvas.width).map { x in
            let pixel = canvas[x, y]
            return String(format: "%02x%02x%02x", pixel.red, pixel.green, pixel.blue)
        }.joined()
    }
}

private let utc = TimeZone(identifier: "UTC")!

@Suite struct UsageCircleOracleTests {
    @Test func everyCaseReproducesTheApprovedFramesExactly() throws {
        let oracle = try loadCircleOracle()
        #expect(oracle.timeZone == "UTC")
        #expect(oracle.width == PixelCanvas.width)
        #expect(oracle.height == PixelCanvas.height)
        #expect(oracle.cases.isEmpty == false)

        for recorded in oracle.cases {
            let vendor: CodeUsage.Vendor = recorded.vendor == "claude" ? .claude : .zai
            let windows = recorded.windows.map { window in
                (
                    kind: CodeUsage.WindowKind(rawValue: window.kind) ?? .fiveHour,
                    reading: window.percent.map {
                        CodeUsage.Window(
                            percent: $0,
                            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                        )
                    }
                )
            }
            let timeline = CodeUsage.Circle.timeline(
                vendor: vendor,
                windows: windows,
                parameters: CodeUsage.Parameters(
                    resetEvery: TimeInterval(recorded.dwellMs) / 1000,
                    resetAfter: recorded.resetAfter
                ),
                timeZone: utc
            )

            #expect(timeline.count == recorded.frames.count, "\(recorded.id): frame count")
            #expect(
                timeline.map(\.milliseconds) == recorded.frames.map(\.ms),
                "\(recorded.id): delays"
            )
            for (index, (drawn, approved)) in zip(timeline, recorded.frames).enumerated() {
                let rows = circleHexRows(drawn.canvas)
                if rows != approved.rows {
                    let firstBad = rows.indices.first {
                        $0 >= approved.rows.count || rows[$0] != approved.rows[$0]
                    } ?? -1
                    Issue.record("\(recorded.id) frame \(index): first differing row \(firstBad)")
                }
            }
        }
    }
}

@Suite struct UsageCircleTests {
    // The rim is the panel's perimeter walked once — 132 cells, no corner
    // counted twice. At 52 x 16 that is two and a half times the 52 a row's bar
    // gets, which is what puts one cell under a percent.
    @Test func theRimWalksThePerimeterOnce() {
        let rim = CodeUsage.Circle.rim

        #expect(rim.count == 132)
        #expect(Set(rim.map { "\($0.x),\($0.y)" }).count == rim.count)
        // Every cell is ON the edge, and every edge cell is in it.
        let edge = (0..<PixelCanvas.width).flatMap { x in
            (0..<PixelCanvas.height).compactMap { y -> String? in
                let onEdge = x == 0 || y == 0
                    || x == PixelCanvas.width - 1 || y == PixelCanvas.height - 1
                return onEdge ? "\(x),\(y)" : nil
            }
        }
        #expect(Set(rim.map { "\($0.x),\($0.y)" }) == Set(edge))
        // Clockwise from the top-left corner.
        #expect(rim.first.map { ($0.x, $0.y) }.map { $0 == (0, 0) } == true)
        #expect(rim[1].x == 1 && rim[1].y == 0)
    }

    // A reading that exists is never zero cells: one percent has to look
    // different from no data at all.
    @Test func aWindowWithAReadingAlwaysLightsSomething() {
        #expect(CodeUsage.Circle.litCells(nil) == 0)
        #expect(CodeUsage.Circle.litCells(0) == 0)
        #expect(CodeUsage.Circle.litCells(1) == 1)
        #expect(CodeUsage.Circle.litCells(50) == 66)
        #expect(CodeUsage.Circle.litCells(100) == 132)
        // Past the cap the rim is full; it has nowhere to put an overage.
        #expect(CodeUsage.Circle.litCells(140) == 132)
    }

    // The two windows are told apart by the name along the bottom — the period
    // each measures, which is what places the figure above it.
    @Test func eachWindowIsNamedForThePeriodItMeasures() {
        #expect(CodeUsage.WindowKind.fiveHour.name == "5h")
        #expect(CodeUsage.WindowKind.weekly.name == "week")
        #expect(CodeUsage.WindowKind.allCases.count == 2)
    }

    // The session names a time; the week names a date and a time, because
    // "09:00" seven days out says nothing about which day.
    @Test func eachWindowSpellsItsResetTheWayItsPeriodNeeds() {
        let instant = Date(timeIntervalSince1970: 1_790_240_700)

        #expect(CodeUsage.WindowKind.fiveHour.reset(instant, in: utc) == "rst 09:05")
        #expect(CodeUsage.WindowKind.weekly.reset(instant, in: utc) == "rst 24 sep 09:05")
    }

    // Which way round the week's date reads is the reader's, not the
    // vendor's: the day first, or the month first. No comma and no "at" in
    // either — the panel has room for neither, and both are noise at 52
    // columns.
    //
    // The spellings are the same glyphs in a different order, so both are
    // exactly as wide: a reset that fits still fits, and one that marquees
    // still takes the same number of frames to pass. That is why this is a
    // text setting rather than a design change, and why the recorded frames
    // do not enumerate it.
    @Test func theWeeksDateReadsTheWayTheTileWasTold() {
        let instant = Date(timeIntervalSince1970: 1_790_240_700)

        #expect(
            CodeUsage.WindowKind.weekly.reset(instant, in: utc, order: .dayFirst)
                == "rst 24 sep 09:05"
        )
        #expect(
            CodeUsage.WindowKind.weekly.reset(instant, in: utc, order: .monthFirst)
                == "rst sep 24 09:05"
        )
        // The session names no date, so there is no order to put it in.
        #expect(
            CodeUsage.WindowKind.fiveHour.reset(instant, in: utc, order: .monthFirst)
                == "rst 09:05"
        )
        // The day keeps no leading zero in either order.
        let ninth = Date(timeIntervalSince1970: 1_789_030_800)
        #expect(
            CodeUsage.WindowKind.weekly.reset(ninth, in: utc, order: .dayFirst)
                == "rst 10 sep 09:00"
        )
        #expect(
            CodeUsage.WindowKind.weekly.reset(ninth, in: utc, order: .monthFirst)
                == "rst sep 10 09:00"
        )
        // Both spellings are the same width, which is what lets the recorded
        // frames stand for either.
        let font = PixelFont.proportional
        #expect(
            font.width(of: "rst 24 sep 09:05", scale: 1)
                == font.width(of: "rst sep 24 09:05", scale: 1)
        )
    }
}
