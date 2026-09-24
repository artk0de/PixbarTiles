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

private func window(_ oracle: Oracle.Window) -> CodeUsage.Window? {
    oracle.percent.map { percent in
        CodeUsage.Window(
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
            let vendor: CodeUsage.Vendor = recorded.vendor == "claude" ? .claude : .zai
            let config = CodeUsage.Parameters(
                resetEvery: TimeInterval(recorded.resetEveryMs) / 1000,
                resetAfter: recorded.resetAfter
            )
            let timeline = CodeUsage.Compact.timeline(
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
        #expect(CodeUsage.sessionReset(at, in: utc) == "rst 09:05")
    }

    // Day without a leading zero, the month in three lowercase letters, the
    // 24-hour time — and no comma, which the panel has no glyph for.
    @Test func theWeeklyResetIsDayMonthAndTime() {
        let at = Date(timeIntervalSince1970: 1_790_845_200)  // 2026-10-01 09:00 UTC
        #expect(CodeUsage.weeklyReset(at, in: utc) == "rst 1 oct 09:00")
    }

    // A reset is an INSTANT: z.ai's server lives in Asia/Shanghai, and its
    // 21:00 there is the Mac's own hour — 16:00 in Moscow — never Shanghai's.
    @Test func aResetIsSaidInTheZoneTheFaceIsDrawnIn() {
        // 2026-09-28 21:00 in Shanghai (UTC+8) = 13:00 UTC.
        let shanghaiNine = Date(timeIntervalSince1970: 1_790_600_400)
        #expect(CodeUsage.weeklyReset(shanghaiNine, in: moscow) == "rst 28 sep 16:00")
        #expect(CodeUsage.sessionReset(shanghaiNine, in: utc) == "rst 13:00")
    }

    // End to end on the live pro answer of 2026-09-23: the week's
    // `nextResetTime` goes through the decoder and comes out in the Mac's
    // zone — 20:16 in Moscow, not Shanghai's 01:16 on the 27th.
    @Test func theLiveZaiWeeklyResetIsSaidInTheMacsZone() throws {
        let live = Data("""
        {"code":200,"data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":60032,
           "percentage":100,"nextResetTime":1790443012983}
        ],"level":"pro"}}
        """.utf8)
        let resetsAt = try #require(ZaiUsageDecoder.limits(from: live).weekly?.resetsAt)
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))

        #expect(CodeUsage.weeklyReset(resetsAt, in: moscow) == "rst 26 sep 20:16")
        #expect(CodeUsage.weeklyReset(resetsAt, in: shanghai) == "rst 27 sep 01:16")
    }

    // MARK: - What flips

    // A hot row whose window carries no reset date has nothing to flip to:
    // the page stays the percentages rather than inventing a time.
    @Test func aHotRowWithoutAResetDateDoesNotFlip() {
        let timeline = CodeUsage.Compact.timeline(
            vendor: .claude,
            session: CodeUsage.Window(percent: 90, resetsAt: nil),
            weekly: CodeUsage.Window(percent: 20, resetsAt: nil),
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
        let session = CodeUsage.Window(
            percent: 97, resetsAt: Date(timeIntervalSince1970: 1_790_240_700)
        )
        let weekly = CodeUsage.Window(
            percent: 88, resetsAt: Date(timeIntervalSince1970: 1_790_845_200)
        )
        let timeline = CodeUsage.Compact.timeline(
            vendor: .zai, session: session, weekly: weekly, config: .standard, timeZone: utc
        )
        let delivery = CodeUsage.Compact.delivery(
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
        let delivery = CodeUsage.Compact.delivery(
            vendor: .claude,
            session: CodeUsage.Window(percent: 12, resetsAt: nil),
            weekly: nil,
            config: .standard,
            timeZone: utc
        )
        let image = delivery.scene.frames[0].image[0]
        #expect(image.isAnimated == false)
        #expect(image.frameCount == 1)
    }

    // The worst case the panel can be asked for — both rows hot, the longest
    // weekly spelling — stays inside the ceilings this panel was MEASURED at.
    //
    // 478 frames and 135 240 base64 bytes played on time on 2026-09-23; the
    // 50 frames and 60 KB the vendor documents are wrong for this hardware and
    // were never what the pages it plays obey. The bound is here so a design
    // that quietly doubles the frame count has to argue with a number.
    @Test func theLongestMarqueeStaysInsideTheSceneLimits() throws {
        // 2026-09-30 23:59 UTC: two-digit day, the widest digits.
        let late = Date(timeIntervalSince1970: 1_790_812_740)
        let delivery = CodeUsage.Compact.delivery(
            vendor: .claude,
            session: CodeUsage.Window(percent: 104, resetsAt: late),
            weekly: CodeUsage.Window(percent: 100, resetsAt: late),
            config: CodeUsage.Parameters(resetEvery: 300, resetAfter: 50),
            timeZone: utc
        )
        let image = delivery.scene.frames[0].image[0]
        #expect(image.frameCount <= 478)
        #expect(image.base64.utf8.count <= 135_240)
    }
}

@Suite struct UsageFaceConfigTests {
    @Test func theDefaultsAreTenSecondsAndEightyPercent() {
        #expect(CodeUsage.Parameters.standard.resetEvery == 10)
        #expect(CodeUsage.Parameters.standard.resetAfter == 80)
    }

    @Test func thePickersOfferTheDesignsSteps() {
        #expect(CodeUsage.Parameters.resetEverySteps == [5, 10, 15, 30, 60, 120, 300])
        #expect(CodeUsage.Parameters.resetAfterSteps == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100])
    }

    @Test func theConfigRoundTrips() throws {
        let config = CodeUsage.Parameters(resetEvery: 30, resetAfter: 65)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(CodeUsage.Parameters.self, from: data) == config)
    }

    // A record written before either field existed reads as the defaults.
    @Test func aConfigWithoutTheFieldsReadsAsTheDefaults() throws {
        #expect(try JSONDecoder().decode(CodeUsage.Parameters.self, from: Data("{}".utf8)) == .standard)
    }
}

@Suite struct CodeUsageBandTests {
    // One ramp for both vendors; below the first warning the bar is in the
    // vendor's own colour, past it in the shared ramp.
    @Test func bothVendorsShareTheRampWithTheirOwnBrandBelowIt() {
        #expect(CodeUsage.Band(utilization: 74).fillColour(brand: ZaiUsage.brandColour) == "#3B5BFE")
        #expect(CodeUsage.Band(utilization: 74).fillColour(brand: ClaudeUsage.brandColour) == "#D97757")

        let ramp = [75: "#FFD24A", 80: "#FFAE3A", 85: "#FF8C1A",
                    90: "#FF6321", 95: "#FF3B30", 100: "#FF0000"]
        for (percent, colour) in ramp {
            #expect(CodeUsage.Band(utilization: percent)
                .fillColour(brand: ZaiUsage.brandColour) == colour, "\(percent)%")
        }
        // Over a hundred is not impossible — an overage channel keeps serving
        // past the bar — and it must not fall back down the ramp.
        #expect(CodeUsage.Band(utilization: 140).fillColour(brand: ClaudeUsage.brandColour) == "#FF0000")
    }
}

// MARK: - What carries which meaning

// The oracle above pins every pixel of the approved design. These pin the two
// RULES behind it, so a re-recording that quietly changed one of them would
// still have to be argued for here.

private func facePixel(_ vendor: CodeUsage.Vendor, session: Int?, at point: (x: Int, y: Int))
    -> String
{
    let frames = CodeUsage.Compact.timeline(
        vendor: vendor,
        session: session.map { CodeUsage.Window(percent: $0, resetsAt: nil) },
        weekly: CodeUsage.Window(percent: 10, resetsAt: nil),
        config: .standard,
        timeZone: TimeZone(identifier: "UTC")!
    )
    let pixel = frames[0].canvas[point.x, point.y]
    return String(format: "%02X%02X%02X", pixel.red, pixel.green, pixel.blue)
}

/// Every colour the session row's figure is drawn in — its five rows, right of
/// the label and its gap.
///
/// The row is labelled `5h`, which ends at column 15; the gap puts its value
/// area at 20. Scanning from any earlier column reads the label's grey as if
/// it were the figure's ink.
private func figureInk(_ vendor: CodeUsage.Vendor, session: Int?) -> Set<String> {
    var ink: Set<String> = []
    for x in 20..<PixelCanvas.width {
        for y in 1..<6 {
            let hex = facePixel(vendor, session: session, at: (x, y))
            if hex != "000000" { ink.insert(hex) }
        }
    }
    return ink
}

// The figure says WHICH ACCOUNT, which is what the mark beside it says. z.ai's
// mark is near-white where its brand is blue, and blue figures under a white Z
// read as a second vendor on one page.
@Test func theFigureIsDrawnInTheVendorsMarkColour() {
    #expect(figureInk(.zai, session: 17) == ["E8E8E8"])
    #expect(figureInk(.claude, session: 17) == ["D97757"])
}

// It says that only while the window is steady. Past three quarters the figure
// and the bar under it are one statement — how close this is to running out —
// and a warm figure over a warm bar is what the eye lands on first.
@Test func theFigureFollowsTheBarOnceTheWindowIsNoLongerSteady() {
    let ramp = [75: "FFD24A", 80: "FFAE3A", 85: "FF8C1A",
                90: "FF6321", 95: "FF3B30", 100: "FF0000"]
    for (percent, colour) in ramp {
        #expect(figureInk(.zai, session: percent) == [colour], "zai \(percent)%")
        #expect(figureInk(.claude, session: percent) == [colour], "claude \(percent)%")
    }
}

// A steady bar fills bright white against the grey of what is left, so what a
// glance lands on is how much of the window is gone.
@Test func theSpentPartOfASteadyBarIsBrightWhiteAndTheRestIsGrey() {
    // 17% of 52 columns is filled; column 51 is not.
    #expect(facePixel(.claude, session: 17, at: (0, 7)) == "FFFFFF")
    #expect(facePixel(.claude, session: 17, at: (51, 7)) == "303030")
}

// And it turns as the window runs out, five points a step: yellow at three
// quarters through red at the cap. White alone left a bar at a third and a bar
// about to run out the same colour, differing only in length — which is the
// one reading the panel is worst at.
//
// The ramp is `CodeUsage.Band`'s, shared with the AWTRIX page. White stands in for
// the vendor's brand as this face's steady colour: the mark already says which
// account this is, so the bar is free to spend its colour on how much is left.
@Test func aBarTakesItsWarningColourAsTheWindowRunsOut() {
    let ramp = [74: "FFFFFF", 75: "FFD24A", 80: "FFAE3A", 85: "FF8C1A",
                90: "FF6321", 95: "FF3B30", 100: "FF0000", 140: "FF0000"]
    for (percent, colour) in ramp {
        #expect(facePixel(.claude, session: percent, at: (0, 7)) == colour, "claude \(percent)%")
        #expect(facePixel(.zai, session: percent, at: (0, 7)) == colour, "zai \(percent)%")
    }
}

// The track stays grey under every one of them. A warning colour against a
// white rail is a warning fighting its own bar.
@Test func theTrackStaysGreyUnderAWarning() {
    for percent in [85, 92, 99] {
        #expect(facePixel(.claude, session: percent, at: (51, 7)) == "303030", "\(percent)%")
    }
}

// MARK: - The spent pulse

private func usageTimeline(
    session: Int, resetsAt: Date? = nil, config: CodeUsage.Parameters = .standard
) -> [CodeUsage.Frame] {
    CodeUsage.Compact.timeline(
        vendor: .claude,
        session: CodeUsage.Window(percent: session, resetsAt: resetsAt),
        weekly: CodeUsage.Window(percent: 10, resetsAt: nil),
        config: config,
        timeZone: TimeZone(identifier: "UTC")!
    )
}

private func barColour(_ frame: CodeUsage.Frame) -> String {
    let pixel = frame.canvas[0, 7]
    return String(format: "%02X%02X%02X", pixel.red, pixel.green, pixel.blue)
}

// A full window is the one state the ramp cannot shout any louder in colour:
// the band below it already drives the red channel to 255, and going brighter
// at that hue means adding white, which reads as LESS urgent. So past the cap
// the face spends motion instead — and nothing below the cap moves at all.
@Test func onlyAFullWindowTurnsThePercentPhaseIntoAPulse() {
    #expect(usageTimeline(session: 99).count == 1)
    #expect(usageTimeline(session: 100).count > 1)
}

// It breathes between the two reds and nothing else moves: same figure, same
// bar length, same everything but the colour of the row that is full.
@Test func thePulseAlternatesBetweenTheTwoRedsAndMovesNothingElse() {
    let frames = usageTimeline(session: 100)

    #expect(frames.map(barColour).prefix(4) == ["FF0000", "A00000", "FF0000", "A00000"])
    #expect(Set(frames.map(barColour)) == ["FF0000", "A00000"])
    // The weekly row is steady, so it is white in every frame of the pulse.
    for frame in frames {
        let pixel = frame.canvas[0, 15]
        #expect(String(format: "%02X%02X%02X", pixel.red, pixel.green, pixel.blue) == "FFFFFF")
    }
}

// The beats plus the rest come to exactly the interval the tile asked for —
// a pulse that overran it would drift against "show reset every".
@Test func thePulseLastsExactlyAsLongAsThePercentPhaseWouldHave() {
    for seconds in CodeUsage.Parameters.resetEverySteps {
        let config = CodeUsage.Parameters(resetEvery: seconds, resetAfter: 80)
        let total = usageTimeline(session: 100, config: config).reduce(0) { $0 + $1.milliseconds }
        #expect(total == Int(seconds * 1000), "\(seconds)s")
    }
}

// And it holds after a while rather than breathing forever. A pulse that never
// stops stops being read — the same reason the ramp starts as late as it does
// — and a five-minute "show reset every" would otherwise spend the panel's
// whole frame budget on one blinking row.
@Test func aLongPercentPhaseBreathesAndThenHolds() {
    let config = CodeUsage.Parameters(resetEvery: 300, resetAfter: 80)
    let frames = usageTimeline(session: 100, config: config)

    #expect(frames.count == 25)
    #expect(frames.dropLast().allSatisfy { $0.milliseconds == 420 })
    #expect(frames.last?.milliseconds == 300_000 - 420 * 24)
    #expect(barColour(frames[frames.count - 1]) == "FF0000")
}

// The pulse is the percent phase's alone. A row showing its reset is being
// read as TEXT — the session's still, the week's gliding a pixel a frame —
// and text that blinks under the eye is text nobody finishes.
@Test func theResetPhaseHoldsStillEvenWhenTheWindowIsFull() {
    let resetsAt = Date(timeIntervalSince1970: 1_758_672_000)
    let frames = usageTimeline(session: 100, resetsAt: resetsAt)
    let pulse = frames.prefix { $0.milliseconds == 420 }
    let reset = frames.dropFirst(pulse.count)

    #expect(!reset.isEmpty)
    #expect(reset.allSatisfy { barColour($0) == "FF0000" })
}

// A row with nothing to report draws no progress at all — an unlit track from
// end to end, rather than a bar at nought.
@Test func aRowWithNoReadingDrawsNoProgress() {
    #expect(facePixel(.claude, session: nil, at: (51, 7)) == "303030")
    #expect(facePixel(.claude, session: nil, at: (0, 7)) == "303030")
}

// Each row's label starts where its own row has room. The mark is five rows
// tall and stands on the top row alone, so the top label begins after it and
// the bottom one at the panel's edge — nine columns the weekly row was holding
// for a mark that is not there, and exactly the columns its long reset needs.
@Test func eachRowsLabelStartsWhereThatRowHasRoom() {
    let frames = CodeUsage.Compact.timeline(
        vendor: .claude,
        session: CodeUsage.Window(percent: 50, resetsAt: nil),
        weekly: CodeUsage.Window(percent: 50, resetsAt: nil),
        config: .standard,
        timeZone: TimeZone(identifier: "UTC")!
    )
    let canvas = frames[0].canvas

    func firstLitColumn(ofRowAt top: Int) -> Int? {
        (0..<20).first { x in
            (top..<(top + 5)).contains { y in
                let pixel = canvas[x, y]
                return (pixel.red, pixel.green, pixel.blue) == (0x60, 0x60, 0x60)
            }
        }
    }

    #expect(firstLitColumn(ofRowAt: 1) == 9)
    #expect(firstLitColumn(ofRowAt: 9) == 0)
}

// And the reset a row can hold still is centred in what that row has left, not
// right-aligned. For those seconds the reset IS the row's content, and the
// figure's alignment leaves a gap exactly where the eye starts reading.
@Test func aResetThatFitsIsCentredInItsRow() {
    // 14:30 UTC: `rst 14:30` is 31 columns against the 5h row's 32.
    let at = Date(timeIntervalSince1970: 1_790_778_600)
    let frames = CodeUsage.Compact.timeline(
        vendor: .claude,
        session: CodeUsage.Window(percent: 84, resetsAt: at),
        weekly: CodeUsage.Window(percent: 52, resetsAt: nil),
        config: .standard,
        timeZone: TimeZone(identifier: "UTC")!
    )
    let canvas = frames[frames.count - 1].canvas

    // From past the mark, which lives in these same rows and is not grey.
    let firstLit = (9..<PixelCanvas.width).first { x in
        (1..<6).contains { y in
            let pixel = canvas[x, y]
            return (pixel.red, pixel.green, pixel.blue) != (0, 0, 0)
                && (pixel.red, pixel.green, pixel.blue) != (0x60, 0x60, 0x60)
        }
    }

    // The area runs 20..<52 and the message is 31 wide, so the spare column
    // sits on the left: the reset starts at 20, not flush against the edge.
    #expect(firstLit == 20)
}
