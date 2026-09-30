import AppKit
import Foundation
import Testing
@testable import PixbarTilesApp

/// A window opened from the menu bar comes to the front even when macOS
/// refuses the polite activation.
@MainActor
@Suite struct WindowFocusActivationTests {
    @Test func aRefusedPoliteActivationFallsBackToTheForcedOne() {
        var forced = 0
        WindowFocus.activate(polite: { false }, force: { forced += 1 })
        #expect(forced == 1)
    }

    @Test func aGrantedPoliteActivationIsLeftAtThat() {
        var forced = 0
        WindowFocus.activate(polite: { true }, force: { forced += 1 })
        #expect(forced == 0)
    }

    private func shownWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 50, height: 50),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    // The popover lives above ordinary windows: left up, it covers the
    // window it just opened (2026-09-30, the clock's settings under it).
    @Test func aWindowOpenedFromThePopoverTakesThePopoverAway() {
        let popover = shownWindow()
        WindowFocus.stepAside(popover, pinned: false)
        #expect(popover.isVisible == false)
    }

    // Pinned, the panel is a window of its own the user put there.
    @Test func aPinnedPanelStaysWhereItWasPut() {
        let panel = shownWindow()
        WindowFocus.stepAside(panel, pinned: true)
        #expect(panel.isVisible)
        panel.orderOut(nil)
    }
}
