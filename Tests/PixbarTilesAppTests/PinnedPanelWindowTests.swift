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
}
