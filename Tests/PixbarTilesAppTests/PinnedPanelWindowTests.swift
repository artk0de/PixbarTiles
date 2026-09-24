import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PixbarTilesApp

// The pinned window is the panel in a window, not the panel stretched over
// one. Its first appearance covered most of a 1920 px screen with the content
// still laid out at its own ~940: `glassWindow()` fills to infinity so that a
// window dragged bigger than its content still shows material at the edges,
// and under `.windowResizability(.contentSize)` that fill IS the content size.
// Pinning changes where the panel is, not how big.

@MainActor
private func fitting(_ view: some View) -> CGSize {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
}

@MainActor @Suite struct PinnedPanelWindowTests {
    private func parts() -> (AppModel, PanelModel, SettingsModel, PanelPin, UserDefaults) {
        let defaults = UserDefaults(suiteName: "pinned-window-\(UUID().uuidString)")!
        let model = testModel()
        return (model, PanelModel(model: model), SettingsModel(model: model),
                PanelPin(defaults: defaults), defaults)
    }

    @Test func theWindowWrapsThePanelRatherThanStretchingIt() {
        let (model, panel, settings, pin, defaults) = parts()

        let window = fitting(
            PinnedPanelWindow(model: model, panel: panel, settings: settings, pin: pin)
        )
        let bare = fitting(
            MenuPanel(model: model, panel: panel, settings: settings, pin: pin, defaults: defaults)
        )

        #expect(window.width == bare.width)
        #expect(window.height == bare.height)
    }

    // A width that says "as much as you can give me" is the defect itself,
    // stated in the units the window is sized in.
    @Test func theWindowAsksForAFiniteWidth() {
        let (model, panel, settings, pin, _) = parts()

        let size = fitting(
            PinnedPanelWindow(model: model, panel: panel, settings: settings, pin: pin)
        )

        #expect(size.width.isFinite)
        #expect(size.width < 1_000)
    }

    // While the panel is pinned, the menu bar item is only the way back to
    // the window: a click focuses the pinned window, and the popover it would
    // have opened shows nothing of its own — no "Pinned to its own window".
    // The menu bar item's content follows the pin as it changes. Switched in
    // the Scene's body, it did not: a Scene observes nothing, so after an
    // unpin the popover still held the pinned-elsewhere content, and every
    // click reopened the old pinned window where it had been left.
    @Test func theMenuBarContentFollowsThePinBothWays() {
        let (model, panel, settings, pin, _) = parts()
        let host = NSHostingView(rootView: MenuBarContent(
            model: model, panel: panel, settings: settings, pin: pin, windowMoved: { _ in }
        ))

        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 100)

        pin.set(true)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 1)

        pin.set(false)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 100)
    }

    // Pinning from the popover's own pin keeps the panel where it is: the
    // window opens at the popover's top-left, not wherever the scene last
    // left a window.
    @Test func pinningFromThePopoverKeepsThePanelWhereItIs() {
        let (_, _, _, pin, _) = parts()

        pin.pinInPlace(frame: CGRect(x: 700, y: 375, width: 506, height: 254))

        #expect(pin.isPinned)
        #expect(pin.takeDetachedOrigin() == CGPoint(x: 700, y: 629))
    }

    @Test func thePopoverOfAPinnedPanelDrawsNothing() {
        let (_, _, _, pin, _) = parts()

        let size = fitting(PinnedElsewherePanel(pin: pin))

        #expect(size.width <= 1)
        #expect(size.height <= 1)
    }
}
