import Foundation
import Testing
@testable import PixelClockKit

// The weather face's oracle: `Scripts/make_weather_face_oracle.py` records the
// approved mockup's pixels (the `tc002-face-mockup` skill's `weather/wgen.py`
// and `icons.py`) into two fixtures. This suite only pins that both are
// bundled and cover the catalogue; the icon, facts and face suites compare
// against their contents.
@Suite struct WeatherOracleFixtureTests {
    @Test func bothFixturesAreRecordedAndCoverTheCatalogue() throws {
        let icons = try #require(Bundle.module.url(forResource: "weather_icons_oracle", withExtension: "json"))
        let face = try #require(Bundle.module.url(forResource: "weather_face_oracle", withExtension: "json"))
        let iconsJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: icons)) as? [String: Any]
        let names = (iconsJSON?["icons"] as? [String: Any])?.keys.sorted() ?? []
        #expect(names.count == 47)  // the 46 approved animations + nodata
        let faceJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: face)) as? [String: Any]
        let cases = faceJSON?["cases"] as? [[String: Any]] ?? []
        #expect(cases.count >= 30)   // every icon rule × at least one layout, plus the corner cases
    }
}
