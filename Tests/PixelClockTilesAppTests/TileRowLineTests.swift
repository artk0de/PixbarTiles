import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The row's text and badge are computed here and tested here, the way
// `NextRunLine` is — the view that draws them stays thin, and the split means
// a badge bug cannot hide behind a layout bug or the other way round.

@Suite struct TileRowLineTests {
    // A running tile is its name and its latest answer, and nothing else: the
    // two spaces are the row's own spacing, not the renderer's.
    @Test func runningTileDrawsResultWithoutBadge() {
        let line = TileRowLine.drawn(name: "Weather", result: "12°C",
                                     hold: nil, failing: false)
        #expect(line.text == "Weather  12°C")
        #expect(line.badge == nil)
    }

    @Test func aTileWithNoResultYetDrawsItsNameAlone() {
        let line = TileRowLine.drawn(name: "Weather", result: nil,
                                     hold: nil, failing: false)
        #expect(line.text == "Weather")
        #expect(line.badge == nil)
    }

    // The hold already decided WHY the tile is quiet; the line only names it.
    // The names differ from the hold's because the badge speaks to the user.
    @Test func eachHoldDrawsItsBadge() {
        #expect(TileRowLine.drawn(name: "Weather", result: nil, hold: .paused,
                                  failing: false).badge == .paused)
        #expect(TileRowLine.drawn(name: "Weather", result: nil, hold: .hours,
                                  failing: false).badge == .silentHours)
        #expect(TileRowLine.drawn(name: "Weather", result: nil, hold: .focus,
                                  failing: false).badge == .heldByFocus)
    }

    // A failing tile with nothing to show must not invent filler text — the
    // badge is the answer, and an empty result is not papered over.
    @Test func failingOutranksAnEmptyResult() {
        let line = TileRowLine.drawn(name: "Weather", result: nil,
                                     hold: nil, failing: true)
        #expect(line.badge == .failing)
        #expect(line.text == "Weather")
    }
}

@Suite struct AddTileMenuItemTests {
    // The menu renders reasons; it does not compute them. A reason composed
    // elsewhere must survive the item whole.
    @Test func unavailableItemCarriesItsReason() {
        let item = AddTileMenuItem(title: "Weather",
                                   availability: .unavailable(
                                       reason: "already speaking through Kitchen"),
                                   onAdd: {})
        guard case let .unavailable(reason) = item.availability else {
            Issue.record("expected an unavailable item")
            return
        }
        #expect(reason == "already speaking through Kitchen")
    }

    @Test func availableItemIsAvailable() {
        let item = AddTileMenuItem(title: "Weather", availability: .available,
                                   onAdd: {})
        #expect(item.availability == .available)
    }
}
