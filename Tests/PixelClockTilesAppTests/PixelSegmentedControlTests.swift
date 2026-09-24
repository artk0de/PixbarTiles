import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The pixel tab switcher's two decisions that are not drawing: where an
// arrow key moves the selection, and how wide a segment is.

// Arrows move one segment and stop at the ends, as a segmented control's do —
// a switcher that wraps from the last tab to the first is a surprise.
@Test func anArrowMovesOneSegmentAndStopsAtTheEnds() {
    #expect(PixelSegments.step(from: 0, by: 1, count: 3) == 1)
    #expect(PixelSegments.step(from: 2, by: -1, count: 3) == 1)
    #expect(PixelSegments.step(from: 2, by: 1, count: 3) == nil)
    #expect(PixelSegments.step(from: 0, by: -1, count: 3) == nil)
    // A selection the options do not hold lands on the first one.
    #expect(PixelSegments.step(from: nil, by: 1, count: 3) == 0)
    #expect(PixelSegments.step(from: nil, by: 1, count: 0) == nil)
}

// Every segment is as wide as the widest title set in the clock's face plus
// its padding, so the selected field does not change size as it moves.
@Test func everySegmentIsAsWideAsTheWidestTitle() {
    let widest = PanelGlyph.text("General", in: PixelFont.standard)[0].count
    #expect(
        PixelSegments.segmentWidth(titles: ["Tiles", "General"], pixel: 2, padding: 12)
            == CGFloat(widest) * 2 + 24
    )
    #expect(PixelSegments.segmentWidth(titles: [], pixel: 2, padding: 12) == 24)
}
