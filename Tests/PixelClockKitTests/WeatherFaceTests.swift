import Foundation
import Testing
@testable import PixelClockKit

// The TC002 weather face against the approved design: every oracle case's
// timeline — Anchor's icon and area, Pages' and Hybrid's one 52x16 sequence —
// pixel for pixel and delay for delay, and the budget's burst decision. The
// oracle is `Scripts/make_weather_face_oracle.py` over the skill's `wgen.py`;
// a mismatch is a Swift bug, never a reason to re-record.

private let utc = TimeZone(identifier: "UTC")!
private let noon = Date(timeIntervalSince1970: 1_790_172_000)   // 2026-09-23 14:00 UTC

/// Records the first differing frame and row, the way `UsageFaceOracleTests`
/// reports, so a failing case names where to look.
private func compare(_ label: String, _ drawn: [WeatherFace.Frame], _ approved: [WeatherOracle.Frame]?) {
    guard let approved else {
        Issue.record("\(label): the oracle recorded no such timeline")
        return
    }
    #expect(drawn.map(\.milliseconds) == approved.map(\.ms), "\(label): delays")
    #expect(drawn.count == approved.count, "\(label): frame count \(drawn.count) vs \(approved.count)")
    for (index, (frame, expected)) in zip(drawn, approved).enumerated() {
        let rows = WeatherOracle.hexRows(frame.canvas)
        if rows != expected.rows {
            let firstBad = rows.indices.first { $0 >= expected.rows.count || rows[$0] != expected.rows[$0] } ?? -1
            Issue.record("\(label) frame \(index): first differing row \(firstBad)")
            return
        }
    }
}

@Suite struct WeatherFaceOracleTests {
    @Test func everyCaseReproducesTheApprovedFramesExactly() throws {
        let oracle = try WeatherOracle.load()
        #expect(oracle.cases.count == 95)
        for c in oracle.cases {
            let timeline = WeatherFace.timeline(
                reading: c.reading?.appReading, config: try c.config.tileConfig(),
                now: c.now, timeZone: oracle.timeZone
            )
            switch timeline {
            case let .layered(layered):
                compare("\(c.id) icon", layered.icon, c.frames.icon)
                compare("\(c.id) area", layered.area, c.frames.area)
            case let .single(frames):
                compare("\(c.id) full", frames, c.frames.full)
            }
        }
    }

    /// The budget measures the Swift GIF; its decision must be the oracle's.
    @Test func everyComposedCaseTakesTheOraclesBurstDecision() throws {
        let oracle = try WeatherOracle.load()
        for c in oracle.cases where c.config.layout != "anchor" {
            let composed = WeatherFace.composed(
                reading: c.reading?.appReading, config: try c.config.tileConfig(),
                now: c.now, timeZone: oracle.timeZone
            )
            #expect(composed.burstMilliseconds == c.burst, "\(c.id) burst")
        }
    }

    @Test func theOverBudgetCaseFallsBackToBursts() throws {
        let oracle = try WeatherOracle.load()
        let c = try #require(oracle.cases.first { $0.id == "over-budget-storm-all-hybrid" })
        #expect(c.burst == WeatherFace.burstMilliseconds)
        let composed = WeatherFace.composed(
            reading: c.reading?.appReading, config: try c.config.tileConfig(),
            now: c.now, timeZone: oracle.timeZone
        )
        #expect(composed.burstMilliseconds == WeatherFace.burstMilliseconds)
        #expect(composed.frames.count <= WeatherFace.maxFrames)
    }
}

@Suite struct WeatherFaceTests {
    private func reading(code: Int = 61) -> WeatherReading {
        WeatherReading(
            code: code, isDay: true, temperature: 8, apparentTemperature: 6, precipitation: 0,
            windSpeed: 10, interval: 900, relativeHumidity: 70
        )
    }

    private func onlyHumidity(_ layout: WeatherTileConfig.Layout) -> WeatherTileConfig {
        WeatherTileConfig(
            place: Coordinates(latitude: 0, longitude: 0), showsHumidity: true, showsFeelsLike: false,
            layout: layout, showsWind: false, showsHiLo: false, showsRainChance: false, showsHourly: false
        )
    }

    @Test func aLayoutWithOneDetailIsAStill() {
        // Anchor: one 1000 ms area frame; the icon loops on its own.
        guard case let .layered(anchor) = WeatherFace.timeline(
            reading: reading(), config: onlyHumidity(.anchor), now: noon, timeZone: utc
        ) else { Issue.record("anchor is layered"); return }
        #expect(anchor.area.map(\.milliseconds) == [1_000])

        // Hybrid: no slide — the line's own icon plays one whole loop beside a
        // still area.
        guard case let .single(hybrid) = WeatherFace.timeline(
            reading: reading(), config: onlyHumidity(.hybrid), now: noon, timeZone: utc
        ) else { Issue.record("hybrid is single"); return }
        let icon = WeatherIcon.humidity.frames
        #expect(hybrid.count == icon.count)
        #expect(hybrid.map(\.milliseconds).reduce(0, +) == icon.map(\.milliseconds).reduce(0, +))
        let areas = Set(hybrid.map { frame in
            (0..<16).map { y in (18..<52).map { x in frame.canvas[x, y] } }.description
        })
        #expect(areas.count == 1)
    }

    @Test func noReadingDrawsDashesAndTheGreyCloud() {
        let config = WeatherTileConfig(place: Coordinates(latitude: 0, longitude: 0))
        guard case let .layered(layered) = WeatherFace.timeline(
            reading: nil, config: config, now: noon, timeZone: utc
        ) else { Issue.record("anchor is layered"); return }
        #expect(layered.icon.map(\.canvas) == WeatherIcon.nodata.frames.map(\.canvas))
        let dim = Pixel(red: 0x40, green: 0x40, blue: 0x40)
        let area = layered.area[0].canvas
        #expect(area.width == 34 && area.height == 16)
        // The big dash's bar (row 4 of the 5x9 face), and the `n` of `no data`.
        #expect(area[0, 4] == dim && area[2, 4] == dim)
        #expect(area[0, 11] == dim)
        #expect(layered.area.map(\.milliseconds) == [1_000])
    }
}

@Suite struct WeatherFaceDeliveryTests {
    private let config = WeatherTileConfig(place: Coordinates(latitude: 0, longitude: 0))
    private let reading = WeatherReading(
        code: 95, isDay: true, temperature: 22.4, apparentTemperature: 25.1, precipitation: 0,
        windSpeed: 21.6, interval: 900, relativeHumidity: 78, windDirection: 225, windGusts: 54
    )

    private func gif(_ frames: [WeatherFace.Frame]) throws -> Data {
        try FullFrameGif.encode(
            frames: frames.map(\.canvas), delays: frames.map { TimeInterval($0.milliseconds) / 1000 }
        )
    }

    /// Anchor ships two GIFs in one frame: the icon at the panel's origin and
    /// the right area beside the gutter, each the encoder's own bytes.
    @Test func anchorShipsTheIconAndTheAreaAsTwoImages() throws {
        let delivery = WeatherFace.delivery(reading: reading, config: config, now: noon, timeZone: utc)
        guard case let .layered(layered) = WeatherFace.timeline(
            reading: reading, config: config, now: noon, timeZone: utc
        ) else { Issue.record("anchor is layered"); return }

        #expect(delivery.scene.frames.count == 1)
        let frame = delivery.scene.frames[0]
        #expect(frame.duration == 5 && frame.draw.isEmpty)
        #expect(frame.image.count == 2)
        let icon = frame.image[0], area = frame.image[1]
        #expect(icon.position == (0, 0) && icon.pixelSize == (16, 16))
        #expect(area.position == (18, 0) && area.pixelSize == (34, 16))
        #expect(icon.frameCount == layered.icon.count && icon.isAnimated == (layered.icon.count > 1))
        #expect(area.frameCount == layered.area.count && area.isAnimated == (layered.area.count > 1))
        #expect(Data(base64Encoded: icon.base64) == (try gif(layered.icon)))
        #expect(Data(base64Encoded: area.base64) == (try gif(layered.area)))
        _ = try delivery.scene.jsonObject()
    }

    @Test func pagesAndHybridShipOnePanelSizedImage() throws {
        for layout in [WeatherTileConfig.Layout.pages, .hybrid] {
            var config = config
            config.layout = layout
            let delivery = WeatherFace.delivery(reading: reading, config: config, now: noon, timeZone: utc)
            guard case let .single(frames) = WeatherFace.timeline(
                reading: reading, config: config, now: noon, timeZone: utc
            ) else { Issue.record("\(layout) is single"); continue }
            let images = delivery.scene.frames[0].image
            #expect(images.count == 1, "\(layout)")
            let image = try #require(images.first)
            #expect(image.position == (0, 0) && image.pixelSize == (52, 16), "\(layout)")
            #expect(image.frameCount == frames.count && image.isAnimated, "\(layout)")
            #expect(Data(base64Encoded: image.base64) == (try gif(frames)), "\(layout)")
        }
    }

    /// Every recorded case — the worst of them 478 frames — is a scene the
    /// clock accepts under the measured ceilings.
    @Test func everyOracleCasesDeliveryPassesTheScenesCeilings() throws {
        let oracle = try WeatherOracle.load()
        var mostFrames = 0
        for c in oracle.cases {
            let delivery = WeatherFace.delivery(
                reading: c.reading?.appReading, config: try c.config.tileConfig(),
                now: c.now, timeZone: oracle.timeZone
            )
            #expect(throws: Never.self, "\(c.id)") { _ = try delivery.scene.jsonObject() }
            mostFrames = max(mostFrames, delivery.scene.frames[0].image.map(\.frameCount).max() ?? 0)
        }
        #expect(mostFrames > 50)
        #expect(mostFrames <= WeatherFace.maxFrames)
    }
}
