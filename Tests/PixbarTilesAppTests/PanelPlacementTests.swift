import Foundation
import Testing
@testable import PixbarTilesApp

/// The panel hangs to the RIGHT of its menu bar item: its left edge under the
/// item's, drawn no wider than the room left before the screen's edge.
@Suite struct PanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let item = CGRect(x: 1077, y: 944, width: 24, height: 24)

    @Test func theRoomIsFromTheItemToTheScreensRightEdge() {
        #expect(PanelPlacement.room(item: item, visible: screen) == 435)
    }

    @Test func aWidthThatFitsStartsUnderTheItem() {
        #expect(PanelPlacement.originX(width: 400, item: item, visible: screen) == 1077)
    }

    @Test func aWidthThatDoesNotFitIsDrawnToTheRoom() {
        #expect(PanelPlacement.shownWidth(stored: 505.6, room: 435) == 435)
        #expect(PanelPlacement.shownWidth(stored: 400, room: 435) == 400)
        #expect(PanelPlacement.shownWidth(stored: 505.6, room: nil) == 505.6)
    }

    // Never narrower than the design: an item at the screen's far right
    // leaves less room than the panel was ever drawn at, and there the panel
    // stays whole and is pulled left instead.
    @Test func tooLittleRoomKeepsTheDesignWidthAndStaysOnScreen() {
        let farRight = CGRect(x: 1400, y: 944, width: 24, height: 24)
        let room = PanelPlacement.room(item: farRight, visible: screen)
        #expect(PanelPlacement.shownWidth(stored: 505.6, room: room) == PanelWidth.designed)
        #expect(PanelPlacement.originX(width: PanelWidth.designed, item: farRight, visible: screen) == CGFloat(1192))
    }
}
