import Foundation
import Testing
@testable import PixbarKit

// The weather face's oracle: `Scripts/make_weather_face_oracle.py` records the
// approved mockup's pixels (the `tc002-face-mockup` skill's `weather/wgen.py`
// and `icons.py`) into two fixtures, read through `WeatherOracle`. This suite
// pins that both are bundled, decode, and cover the catalogue; the icon, facts
// and face suites compare against their contents.
@Suite struct WeatherOracleFixtureTests {
    @Test func bothFixturesAreRecordedAndCoverTheCatalogue() throws {
        let oracle = try WeatherOracle.load()
        #expect(oracle.icons.count == 47)   // the 46 approved animations + nodata
        #expect(oracle.icons["nodata"] != nil)
        #expect(oracle.cases.count >= 30)   // every icon rule × at least one layout, plus the corner cases
        #expect(oracle.timeZone == TimeZone(identifier: "UTC"))
    }

    @Test func everyCaseInflatesToTheTimelinesItsLayoutPlays() throws {
        for recorded in try WeatherOracle.load().cases {
            let frames = recorded.frames
            if recorded.config.layout == "anchor" {
                #expect((frames.icon?.count ?? 0) > 0, "\(recorded.id) icon")
                #expect((frames.area?.count ?? 0) > 0, "\(recorded.id) area")
                #expect(frames.full == nil, "\(recorded.id)")
                #expect(frames.area?.allSatisfy { $0.rows.count == 16 && $0.rows[0].count == 34 * 6 } == true)
            } else {
                #expect((frames.full?.count ?? 0) > 0, "\(recorded.id) full")
                #expect(frames.full?.allSatisfy { $0.rows.count == 16 && $0.rows[0].count == 52 * 6 } == true)
                #expect((frames.full?.count ?? 0) <= 480, "\(recorded.id) passes the frame ceiling")
            }
        }
    }

    @Test func theOverBudgetCaseIsRecordedWithItsBurst() throws {
        let cases = try WeatherOracle.load().cases
        let over = try #require(cases.first { $0.id == "over-budget-storm-all-hybrid" })
        #expect(over.burst == 2_000)
        #expect(cases.filter { $0.burst != nil }.map(\.id) == ["over-budget-storm-all-hybrid"])
    }

    @Test func iconRowsExpandToTheSameHexACanvasProduces() throws {
        let oracle = try WeatherOracle.load()
        let nodata = try #require(oracle.icons["nodata"])
        let rows = nodata.hexRows(nodata.frames[0])
        #expect(rows.count == 16 && rows.allSatisfy { $0.count == 16 * 6 })
        #expect(WeatherOracle.hexRows(PixelCanvas(width: 16, height: 16)) == Array(repeating: String(repeating: "0", count: 96), count: 16))
    }

    @Test func glyphTablesCoverBothFaces() throws {
        let glyphs = try WeatherOracle.load().glyphs
        #expect(glyphs["small"]?["⇗"]?.count == 5)
        #expect(glyphs["big"]?["0"]?.count == 9)
    }
}
