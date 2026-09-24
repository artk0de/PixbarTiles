import AppKit
import Foundation
import Testing
@testable import PixbarTilesApp

// Drag-to-pin pins where the drag is LET GO. Pinning on the first move opened
// the window where the drag began while the user went on dragging the popover
// somewhere else: two copies of the panel, neither where it was put.

@Test func aMoveWithNoButtonDownIsThePopoverBeingPlacedNotDragged() {
    var drag = PanelDrag()

    let following = drag.moved(topLeft: CGPoint(x: 900, y: 1000), buttonDown: false, pinned: false)
    let origin = drag.released(buttonDown: false)
    #expect(following == false)
    #expect(origin == nil)
}

@Test func aDragPinsAtWhereItIsLetGoNotWhereItBegan() {
    var drag = PanelDrag()

    let following = drag.moved(topLeft: CGPoint(x: 900, y: 1000), buttonDown: true, pinned: false)
    _ = drag.moved(topLeft: CGPoint(x: 600, y: 800), buttonDown: true, pinned: false)
    _ = drag.moved(topLeft: CGPoint(x: 300, y: 500), buttonDown: true, pinned: false)
    let whileHeld = drag.released(buttonDown: true)
    let letGo = drag.released(buttonDown: false)

    #expect(following)
    #expect(whileHeld == nil)
    #expect(letGo == CGPoint(x: 300, y: 500))
}

@Test func aReleasedDragPinsOnce() {
    var drag = PanelDrag()
    _ = drag.moved(topLeft: CGPoint(x: 300, y: 500), buttonDown: true, pinned: false)

    let first = drag.released(buttonDown: false)
    let second = drag.released(buttonDown: false)
    #expect(first == CGPoint(x: 300, y: 500))
    #expect(second == nil)
}

@Test func aPinnedPanelIsNotPinnedAgainByAMove() {
    var drag = PanelDrag()

    let following = drag.moved(topLeft: CGPoint(x: 300, y: 500), buttonDown: true, pinned: true)
    let origin = drag.released(buttonDown: false)
    #expect(following == false)
    #expect(origin == nil)
}

/// Focus goes to the pinned window alone: activating with no options brings
/// the key and main windows forward, `.activateAllWindows` every window the
/// app has — Settings, the store, a clock's settings — over the user's work.
@MainActor @Test func focusingThePinnedWindowDoesNotRaiseTheAppsOtherWindows() {
    #expect(WindowFocus.activation.contains(.activateAllWindows) == false)
}

@MainActor @Test func thePinnedWindowIsFoundByItsSceneIdAmongTheAppsWindows() {
    let window = { (id: String) -> NSWindow in
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(id)
        return window
    }
    let other = window("com_apple_SwiftUI_Settings_window")
    let pinned = window("\(PinnedPanelWindow.id)-AppWindow-1")

    #expect(WindowFocus.pinnedWindow(among: [other, pinned]) === pinned)
    #expect(WindowFocus.pinnedWindow(among: [other]) == nil)
}
