// Tests/PixelClockTilesAppTests/TileReorderTests.swift
import Testing
@testable import PixelClockTilesApp

// Where a dragged tile lands.
//
// The two sides of this drag speak different languages, and nothing was
// translating: SwiftUI's `onMove(from:to:)` gives an INSERTION index — the
// slot the row is dropped before, counted with the row still in the list —
// and `AppModel.moveTile(_:to:)` takes the row whose PLACE the dragged one
// takes. Passed through unchanged, every downward drag went one row too far,
// and there was no test to notice because the window has none.

@Suite struct TileReorderTests {
    // [weather, claude, anecdotes] — drag weather down one slot. SwiftUI says
    // "insert at 2"; the row it should take the place of is claude, at 1.
    // Unchanged, this landed on anecdotes and the tile went to the end.
    @Test func draggingDownOneSlotLandsOnTheNeighbourNotPastIt() {
        #expect(TileReorder.landing(draggedFrom: 0, insertedAt: 2, count: 3) == 1)
    }

    // Dragging up, the insertion index already IS the row being displaced:
    // nothing has been pulled up by the removal ahead of it.
    @Test func draggingUpLandsOnTheRowItIsDroppedBefore() {
        #expect(TileReorder.landing(draggedFrom: 2, insertedAt: 0, count: 3) == 0)
        #expect(TileReorder.landing(draggedFrom: 2, insertedAt: 1, count: 3) == 1)
    }

    // The bottom of the list: an insertion index of `count` is "past the last
    // row", which is the last row's place.
    @Test func draggingToTheEndLandsOnTheLastRow() {
        #expect(TileReorder.landing(draggedFrom: 0, insertedAt: 3, count: 3) == 2)
    }

    // A drag that puts the row back where it came from moves nothing, and
    // must not spend a write: `moveTile` would refuse it, but a refusal that
    // travels is still a rebuild of the whole list.
    @Test func aDragThatChangesNothingAnswersNothing() {
        #expect(TileReorder.landing(draggedFrom: 1, insertedAt: 1, count: 3) == nil)
        #expect(TileReorder.landing(draggedFrom: 1, insertedAt: 2, count: 3) == nil)
    }

    // Indices from outside the list are refused rather than clamped: a clamp
    // turns a nonsense drag into a real move of the wrong row.
    @Test func anIndexOutsideTheListIsRefused() {
        #expect(TileReorder.landing(draggedFrom: 0, insertedAt: 9, count: 3) == nil)
        #expect(TileReorder.landing(draggedFrom: 5, insertedAt: 1, count: 3) == nil)
        #expect(TileReorder.landing(draggedFrom: 0, insertedAt: 0, count: 0) == nil)
    }
}
