import Foundation
import Testing
@testable import PixelClockTilesApp

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

    @Test func unpinningIsRememberedToo() {
        let defaults = freshDefaults()
        let pin = PanelPin(defaults: defaults)
        pin.toggle()
        pin.toggle()

        #expect(pin.isPinned == false)
        #expect(PanelPin(defaults: defaults).isPinned == false)
    }
}
