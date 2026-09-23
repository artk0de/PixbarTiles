// Tests/PixelClockKitTests/WeatherIconTests.swift
import Testing
@testable import PixelClockKit

// The weather face's 16x16 animations. The approved art is the skill's
// `weather/icons.py` (plus `wgen.nodata_icon`), recorded frame by frame into
// `weather_icons_oracle.json`; `WeatherIcon.frames` must reproduce every
// pixel and every delay. A mismatch is a porting bug in `WeatherIconArt`.

@Suite struct WeatherIconTests {
    @Test func theCatalogueIsExactlyTheApprovedOne() throws {
        let oracle = try WeatherOracle.load()
        #expect(Set(WeatherIcon.allCases.map(\.rawValue)) == Set(oracle.icons.keys))
        #expect(WeatherIcon.allCases.count == 47)
    }

    @Test func everyIconReproducesTheApprovedAnimationExactly() throws {
        let oracle = try WeatherOracle.load()
        for icon in WeatherIcon.allCases {
            let approved = try #require(oracle.icons[icon.rawValue], "\(icon.rawValue) not recorded")
            let drawn = icon.frames
            #expect(drawn.map(\.milliseconds) == approved.frames.map(\.ms), "\(icon.rawValue): delays")
            #expect(drawn.count == approved.frames.count, "\(icon.rawValue): frame count")
            for (index, (frame, want)) in zip(drawn, approved.frames).enumerated() {
                #expect(frame.canvas.width == 16 && frame.canvas.height == 16, "\(icon.rawValue): size")
                let rows = WeatherOracle.hexRows(frame.canvas)
                let wanted = approved.hexRows(want)
                if rows != wanted {
                    let firstBad = rows.indices.first { $0 >= wanted.count || rows[$0] != wanted[$0] } ?? -1
                    Issue.record("\(icon.rawValue) frame \(index): first differing row \(firstBad)")
                }
            }
        }
    }
}
