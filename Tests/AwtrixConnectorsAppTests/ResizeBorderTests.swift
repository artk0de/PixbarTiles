import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AwtrixConnectorsApp

// The drag itself needs a window, an active app and a pointer, none of which
// exists inside `swift test`. What it hands off to does not: every grip turns a
// pointer that has moved somewhere into a size, and the direction it turns it in
// is the half a person notices immediately — an edge that shrinks when it is
// pulled outwards is not a subtle defect. That arithmetic is here.
// `docs/HANDOFF.md` carries what only a pointer can settle.

// MARK: - Which way is bigger

// The rule the whole border is built on: pulling a grip AWAY from the surface
// makes the surface bigger, whichever grip it is. The two sides disagree about
// which direction that is, which is the entire reason each grip carries its own.
@Test func pullingAnyVerticalEdgeOutwardsWidensTheSurface() {
    let start = CGSize(width: 320, height: 280)

    let pulledRight = ResizeGrip.trailing.size(from: start, movedBy: CGVector(dx: 40, dy: 0))
    let pulledLeft = ResizeGrip.leading.size(from: start, movedBy: CGVector(dx: -40, dy: 0))

    #expect(pulledRight.width == 360)
    #expect(pulledLeft.width == 360)
}

// And inwards is narrower, on both sides. A grip that only ever grew would be a
// one-way door: the floor is what stops a surface disappearing, not the gesture.
@Test func pushingAnyVerticalEdgeInwardsNarrowsTheSurface() {
    let start = CGSize(width: 320, height: 280)

    #expect(ResizeGrip.trailing.size(from: start, movedBy: CGVector(dx: -40, dy: 0)).width == 280)
    #expect(ResizeGrip.leading.size(from: start, movedBy: CGVector(dx: 40, dy: 0)).width == 280)
}

// The sign that is easy to get backwards, and the reason this test exists on its
// own. `NSEvent.mouseLocation` has y growing UPWARDS from the bottom of the
// screen, and a surface grows DOWNWARDS from the menu bar it hangs off. So the
// bottom edge getting taller is the pointer's y getting smaller, and an
// implementation that added the two would grow the History by dragging its
// bottom edge towards the menu bar.
@Test func draggingTheBottomEdgeDownMakesTheSurfaceTaller() {
    let start = CGSize(width: 320, height: 280)

    let draggedDown = ResizeGrip.bottom.size(from: start, movedBy: CGVector(dx: 0, dy: -60))
    let draggedUp = ResizeGrip.bottom.size(from: start, movedBy: CGVector(dx: 0, dy: 60))

    #expect(draggedDown.height == 340)
    #expect(draggedUp.height == 220)
}

// The other end of the same axis, and it reads the opposite way: the top edge
// grows by being pulled up, towards the menu bar.
@Test func draggingTheTopEdgeUpMakesTheSurfaceTaller() {
    let start = CGSize(width: 320, height: 280)

    #expect(ResizeGrip.top.size(from: start, movedBy: CGVector(dx: 0, dy: 60)).height == 340)
    #expect(ResizeGrip.top.size(from: start, movedBy: CGVector(dx: 0, dy: -60)).height == 220)
}

// An edge belongs to one axis and must leave the other alone. Without this a
// diagonal wobble on the way down a side would drag the width along with it, and
// the surface would be a size nobody asked for by the time the button came up.
@Test func anEdgeChangesOnlyItsOwnAxis() {
    let start = CGSize(width: 320, height: 280)
    let wobble = CGVector(dx: 25, dy: -25)

    #expect(ResizeGrip.trailing.size(from: start, movedBy: wobble).height == 280)
    #expect(ResizeGrip.leading.size(from: start, movedBy: wobble).height == 280)
    #expect(ResizeGrip.top.size(from: start, movedBy: wobble).width == 320)
    #expect(ResizeGrip.bottom.size(from: start, movedBy: wobble).width == 320)
}

// A corner is both of its edges at once, each keeping its own sense of outward.
// The bottom-right one is the only corner where both axes agree with the naive
// reading, which is why all four are posed.
@Test func aCornerMovesBothAxesInTheSenseOfTheEdgesItJoins() {
    let start = CGSize(width: 320, height: 280)
    let outAndDown = CGVector(dx: 40, dy: -60)

    #expect(
        ResizeGrip.bottomTrailing.size(from: start, movedBy: outAndDown)
            == CGSize(width: 360, height: 340)
    )
    // Away from a bottom-LEFT corner is leftwards and down: the same pointer
    // movement that grew the corner above shrinks this one on the width.
    #expect(
        ResizeGrip.bottomLeading.size(from: start, movedBy: outAndDown)
            == CGSize(width: 280, height: 340)
    )
    // The top pair invert the height instead.
    #expect(
        ResizeGrip.topTrailing.size(from: start, movedBy: outAndDown)
            == CGSize(width: 360, height: 220)
    )
    #expect(
        ResizeGrip.topLeading.size(from: start, movedBy: outAndDown)
            == CGSize(width: 280, height: 220)
    )
}

// MARK: - What the pointer is told

// The requirement in the brief: a border that resizes without saying so is
// indistinguishable from one that does nothing. There is no ink to see, so the
// cursor IS the affordance, and it has to name the axis it is about to move.
@Test @MainActor func eachGripAsksForTheCursorOfTheAxisItMoves() {
    #expect(ResizeGrip.leading.cursor == NSCursor.resizeLeftRight)
    #expect(ResizeGrip.trailing.cursor == NSCursor.resizeLeftRight)
    #expect(ResizeGrip.top.cursor == NSCursor.resizeUpDown)
    #expect(ResizeGrip.bottom.cursor == NSCursor.resizeUpDown)
}

// MARK: - Which grips a surface gets

// A surface whose height is its content's has nothing for a top or bottom edge
// to do, and a grip that does nothing is exactly the thing the brief calls
// indistinguishable from one that resizes silently. So it is not drawn: the two
// vertical sides are the whole border there.
@Test @MainActor func aSurfaceWithNoStoredHeightOffersOnlyTheEdgesThatChangeItsWidth() {
    #expect(ResizeBorder.grips(resizingHeight: false) == [.leading, .trailing])
}

// With both axes it is the whole perimeter, corners included — which is what
// "drag any edge" was asked for rather than "reach for a particular spot".
@Test @MainActor func aSurfaceWithAStoredHeightOffersTheWholePerimeter() {
    #expect(Set(ResizeBorder.grips(resizingHeight: true)) == Set(ResizeGrip.allCases))
    #expect(ResizeBorder.grips(resizingHeight: true).count == 8)
}
