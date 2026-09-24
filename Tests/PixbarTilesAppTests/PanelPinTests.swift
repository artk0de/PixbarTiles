import Foundation
import Testing
@testable import PixbarTilesApp

// The pin is the one panel state that must outlive the panel: a surface that
// unpins itself the moment it loses focus is the thing the pin exists to stop,
// and a pin forgotten at relaunch is one a person has to set every morning.

@MainActor
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "PanelPinTests-\(UUID().uuidString)")!
}

@MainActor @Suite struct PanelPinTests {
    @Test func aPanelStartsUnpinned() {
        #expect(PanelPin(defaults: freshDefaults()).isPinned == false)
    }

    @Test func pinningIsRememberedAcrossALaunch() {
        let defaults = freshDefaults()
        PanelPin(defaults: defaults).toggle()

        // A second pin over the same store is the next launch reading what the
        // last one wrote.
        #expect(PanelPin(defaults: defaults).isPinned)
    }

    // Dragging the popover pins it, and the window it becomes has to appear
    // WHERE IT WAS DRAGGED — a window that pins itself and then jumps back to
    // the middle of the screen is a move the user has to make twice.
    //
    // Taken once, not read: the origin describes one detach. Left behind, the
    // next pin would drag the window back to where the last one happened to
    // land.
    @Test func aDetachRemembersWhereItHappenedExactlyOnce() {
        let pin = PanelPin(defaults: freshDefaults())
        #expect(pin.takeDetachedOrigin() == nil)

        pin.detach(at: CGPoint(x: 120, y: 340))

        #expect(pin.isPinned)
        #expect(pin.takeDetachedOrigin() == CGPoint(x: 120, y: 340))
        #expect(pin.takeDetachedOrigin() == nil)
    }

    // The origin is not persisted: it describes a gesture, and a gesture does
    // not outlive the launch it happened in. The PIN does.
    @Test func theDetachOriginDoesNotOutliveTheLaunch() {
        let defaults = freshDefaults()
        PanelPin(defaults: defaults).detach(at: CGPoint(x: 10, y: 20))

        let next = PanelPin(defaults: defaults)
        #expect(next.isPinned)
        #expect(next.takeDetachedOrigin() == nil)
    }

    @Test func unpinningIsRememberedToo() {
        let defaults = freshDefaults()
        let pin = PanelPin(defaults: defaults)
        pin.toggle()
        pin.toggle()

        #expect(pin.isPinned == false)
        #expect(PanelPin(defaults: defaults).isPinned == false)
    }
}
