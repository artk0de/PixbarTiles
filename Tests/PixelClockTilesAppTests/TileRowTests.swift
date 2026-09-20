import AppKit
import PixelClockKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The row's facts on the screen: what it shows, that an ambient tile shows no
// run control, and that removing asks its question IN PLACE of the row. The
// pure parts (the line, the badge) are pinned in `TileRowLineTests`; here it
// is the wiring that has to reach pixels.

@MainActor
private func drawn(_ value: TileRowValue, confirming: Bool = false) -> Data? {
    let host = NSHostingView(rootView: TileRow(value: value, confirming: confirming))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private func value(
    name: String = "Weather", result: String? = "12°C", hold: TileHold? = nil,
    failure: String? = nil, isAmbient: Bool = false,
    question: String = "Remove Weather from Desk?"
) -> TileRowValue {
    TileRowValue(
        name: name, result: result, hold: hold, failure: failure,
        isAmbient: isAmbient, removeQuestion: question,
        onRun: {}, onDetail: {}, onRemove: {}
    )
}

@MainActor @Suite struct TileRowTests {
    // Each of the three answers changes the drawing on its own: a row that
    // dropped the name, the result or the badge would fail one comparison.
    @Test func aRowDrawsItsNameItsResultAndItsBadge() {
        let base = drawn(value())
        #expect(base != nil)
        #expect(base != drawn(value(name: "Air quality")))
        #expect(base != drawn(value(result: "13°C")))
        #expect(base != drawn(value(hold: .paused)))
        // A held tile's badge is its own, not the failing one.
        #expect(drawn(value(hold: .paused)) != drawn(value(failure: "the feed is down")))
    }

    // Ambient tiles run themselves; the ▶ exists to run a tile by hand, and
    // the row leaves it off for them.
    @Test func anAmbientTileDrawsNoRunControl() {
        #expect(drawn(value(isAmbient: false)) != drawn(value(isAmbient: true)))
    }

    // The question replaces the row: with the same question and a different
    // tile the drawings are EQUAL — the name and result are gone, not pushed
    // aside. And the question is drawn from the value, which is the only
    // place the clock's name lives.
    @Test func confirmingDrawsTheQuestionInPlaceOfTheRow() {
        let confirming = drawn(value(), confirming: true)
        #expect(confirming != nil)
        #expect(confirming != drawn(value()))
        #expect(confirming == drawn(value(name: "Air quality", result: nil,
                                          hold: .paused), confirming: true))
        #expect(confirming != drawn(value(question: "Remove Lamp from Desk?"),
                                    confirming: true))
    }
}
