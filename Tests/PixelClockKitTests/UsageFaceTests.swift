// Tests/PixelClockKitTests/UsageFaceTests.swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PixelClockKit

// The TC002 usage face Claude and z.ai share: the vendor's mark, a session row
// and a weekly row, each a figure over a one-pixel bar, and — for a row past
// the tile's "show reset after" — a second phase naming when the window
// starts again.
//
// The design was approved as the frames the `tc002-face-mockup` skill's
// `gen.py` computes. `Scripts/make_usage_face_oracle.py` records those frames
// into `usage_face_oracle.json`; the Swift face is held to them pixel for
// pixel and delay for delay. A difference here is a difference from what was
// approved on the clock — change the design in gen.py and re-record, never
// the fixture by hand.

private struct Oracle: Decodable {
    struct Window: Decodable {
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
        let session: Window
        let weekly: Window
        let resetEveryMs: Int
        let resetAfter: Int
        let frames: [Frame]
    }

    let timeZone: String
    let width: Int
    let height: Int
    let cases: [Case]
}

private func loadOracle() throws -> Oracle {
    let url = try #require(Bundle.module.url(
        forResource: "usage_face_oracle", withExtension: "json"
    ))
    return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
}

/// A canvas as the oracle spells it: sixteen rows of packed `rrggbb` hex.
private func hexRows(_ canvas: PixelCanvas) -> [String] {
    (0..<canvas.height).map { y in
        (0..<canvas.width).map { x in
            let pixel = canvas[x, y]
            return String(format: "%02x%02x%02x", pixel.red, pixel.green, pixel.blue)
        }.joined()
    }
}

private func window(_ oracle: Oracle.Window) -> UsageFace.Window? {
    oracle.percent.map { percent in
        UsageFace.Window(
            percent: percent,
            resetsAt: oracle.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private let utc = TimeZone(identifier: "UTC")!

@Suite struct UsageFaceOracleTests {
    @Test func everyCaseReproducesTheApprovedFramesExactly() throws {
        let oracle = try loadOracle()
        #expect(oracle.timeZone == "UTC")
        #expect(oracle.cases.isEmpty == false)
        for recorded in oracle.cases {
            let vendor: UsageFace.Vendor = recorded.vendor == "claude" ? .claude : .zai
            let config = UsageFaceConfig(
                resetEvery: TimeInterval(recorded.resetEveryMs) / 1000,
                resetAfter: recorded.resetAfter
            )
            let timeline = UsageFace.timeline(
                vendor: vendor,
                session: window(recorded.session),
                weekly: window(recorded.weekly),
                config: config,
                timeZone: utc
            )

            #expect(
                timeline.map(\.milliseconds) == recorded.frames.map(\.ms),
                "\(recorded.id): delays"
            )
            #expect(timeline.count == recorded.frames.count, "\(recorded.id): frame count")
            for (index, (drawn, approved)) in zip(timeline, recorded.frames).enumerated() {
                let rows = hexRows(drawn.canvas)
                if rows != approved.rows {
                    let firstBad = rows.indices.first { $0 >= approved.rows.count || rows[$0] != approved.rows[$0] } ?? -1
                    Issue.record("\(recorded.id) frame \(index): first differing row \(firstBad)")
                }
            }
        }
    }
}

@Suite struct UsageFaceTests {
    private let moscow = TimeZone(identifier: "Europe/Moscow")!

    // MARK: - Reset spellings

    @Test func theSessionResetIsHoursAndMinutes() {
        let at = Date(timeIntervalSince1970: 1_790_240_700)  // 2026-09-24 09:05 UTC
        #expect(UsageFace.sessionReset(at, in: utc) == "rst 09:05")
    }

    // Day without a leading zero, the month in three lowercase letters, the
    // 24-hour time — and no comma, which the panel has no glyph for.
    @Test func theWeeklyResetIsDayMonthAndTime() {
        let at = Date(timeIntervalSince1970: 1_790_845_200)  // 2026-10-01 09:00 UTC
        #expect(UsageFace.weeklyReset(at, in: utc) == "rst 1 oct 09:00")
    }

    // A reset is an INSTANT: z.ai's server lives in Asia/Shanghai, and its
    // 21:00 there is the Mac's own hour — 16:00 in Moscow — never Shanghai's.
    @Test func aResetIsSaidInTheZoneTheFaceIsDrawnIn() {
        // 2026-09-28 21:00 in Shanghai (UTC+8) = 13:00 UTC.
        let shanghaiNine = Date(timeIntervalSince1970: 1_790_600_400)
        #expect(UsageFace.weeklyReset(shanghaiNine, in: moscow) == "rst 28 sep 16:00")
        #expect(UsageFace.sessionReset(shanghaiNine, in: utc) == "rst 13:00")
    }

    // MARK: - What flips

    // A hot row whose window carries no reset date has nothing to flip to:
    // the page stays the percentages rather than inventing a time.
    @Test func aHotRowWithoutAResetDateDoesNotFlip() {
        let timeline = UsageFace.timeline(
            vendor: .claude,
            session: UsageFace.Window(percent: 90, resetsAt: nil),
            weekly: UsageFace.Window(percent: 20, resetsAt: nil),
            config: .standard,
            timeZone: utc
        )
        #expect(timeline.count == 1)
        #expect(timeline[0].milliseconds == 10_000)
    }

    // MARK: - Delivery

    // The whole timeline ships as ONE full-frame GIF at the panel's origin,
    // each frame's delay its own — the envelope the TC002 measured (§6f).
    @Test func theTimelineShipsAsOneGifWithItsOwnDelays() throws {
        let session = UsageFace.Window(
            percent: 97, resetsAt: Date(timeIntervalSince1970: 1_790_240_700)
        )
        let weekly = UsageFace.Window(
            percent: 88, resetsAt: Date(timeIntervalSince1970: 1_790_845_200)
        )
        let timeline = UsageFace.timeline(
            vendor: .zai, session: session, weekly: weekly, config: .standard, timeZone: utc
        )
        let delivery = UsageFace.delivery(
            vendor: .zai, session: session, weekly: weekly, config: .standard, timeZone: utc
        )

        #expect(delivery.scene.frames.count == 1)
        let frame = delivery.scene.frames[0]
        #expect(frame.draw.isEmpty)
        #expect(frame.image.count == 1)
        let image = frame.image[0]
        #expect(image.position.x == 0 && image.position.y == 0)
        #expect(image.pixelSize.width == 52 && image.pixelSize.height == 16)
        #expect(image.isAnimated)
        #expect(image.frameCount == timeline.count)
        #expect(
            Data(base64Encoded: image.base64)
                == (try FullFrameGif.encode(
                    frames: timeline.map(\.canvas),
                    delays: timeline.map { TimeInterval($0.milliseconds) / 1000 }
                ))
        )
        // Inside every measured limit, so the scene always encodes.
        #expect((try delivery.scene.jsonObject()).isEmpty == false)
    }

    // Nothing hot is one frame: a still, and said as one.
    @Test func aQuietPageIsAStill() {
        let delivery = UsageFace.delivery(
            vendor: .claude,
            session: UsageFace.Window(percent: 12, resetsAt: nil),
            weekly: nil,
            config: .standard,
            timeZone: utc
        )
        let image = delivery.scene.frames[0].image[0]
        #expect(image.isAnimated == false)
        #expect(image.frameCount == 1)
    }

    // The worst case the panel can be asked for — both rows hot, the longest
    // weekly spelling — stays well inside the documented GIF ceilings.
    @Test func theLongestMarqueeStaysInsideTheSceneLimits() throws {
        // 2026-09-30 23:59 UTC: two-digit day, the widest digits.
        let late = Date(timeIntervalSince1970: 1_790_812_740)
        let delivery = UsageFace.delivery(
            vendor: .claude,
            session: UsageFace.Window(percent: 104, resetsAt: late),
            weekly: UsageFace.Window(percent: 100, resetsAt: late),
            config: UsageFaceConfig(resetEvery: 300, resetAfter: 50),
            timeZone: utc
        )
        let image = delivery.scene.frames[0].image[0]
        #expect(image.frameCount <= 50)
        #expect(image.base64.utf8.count <= 60_000)
    }
}

@Suite struct UsageFaceConfigTests {
    @Test func theDefaultsAreTenSecondsAndEightyPercent() {
        #expect(UsageFaceConfig.standard.resetEvery == 10)
        #expect(UsageFaceConfig.standard.resetAfter == 80)
    }

    @Test func thePickersOfferTheDesignsSteps() {
        #expect(UsageFaceConfig.resetEverySteps == [5, 10, 15, 30, 60, 120, 300])
        #expect(UsageFaceConfig.resetAfterSteps == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100])
    }

    @Test func theConfigRoundTrips() throws {
        let config = UsageFaceConfig(resetEvery: 30, resetAfter: 65)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(UsageFaceConfig.self, from: data) == config)
    }

    // A record written before either field existed reads as the defaults.
    @Test func aConfigWithoutTheFieldsReadsAsTheDefaults() throws {
        #expect(try JSONDecoder().decode(UsageFaceConfig.self, from: Data("{}".utf8)) == .standard)
    }
}

@Suite struct UsageBandTests {
    // One set of thresholds for both vendors; below the first warning the
    // figure is in the vendor's own colour, past it in the shared warnings.
    @Test func bothVendorsShareTheBandsWithTheirOwnBrandBelowThem() {
        #expect(UsageBand(utilization: 79).fillColour(brand: ZaiUsage.brandColour) == "#3B5BFE")
        #expect(UsageBand(utilization: 79).fillColour(brand: ClaudeUsage.brandColour) == "#D97757")
        #expect(UsageBand(utilization: 80).fillColour(brand: ZaiUsage.brandColour) == "#FFD24A")
        #expect(UsageBand(utilization: 90).fillColour(brand: ZaiUsage.brandColour) == "#FF8C1A")
        #expect(UsageBand(utilization: 95).fillColour(brand: ZaiUsage.brandColour) == "#FF3B30")
        #expect(UsageBand(utilization: 140).fillColour(brand: ClaudeUsage.brandColour) == "#FF3B30")
    }
}
