import AppKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The window's material has to reach the titlebar. `containerBackground`
// paints the window's content, and the titlebar kept its own opaque band on
// top of it — the dark strip over a material window the user reported. These
// pin the two halves: what a window is told, and that `glassWindow()` tells it.

@MainActor
private func aTitledWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true
    )
}

@MainActor @Suite struct GlassTitlebarTests {
    @Test func aGlassTitlebarIsTransparentAndTheContentRunsUnderIt() {
        let window = aTitledWindow()
        #expect(window.titlebarAppearsTransparent == false)

        window.adoptGlassTitlebar()

        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
        // The window keeps being a titled, resizable window: the chrome goes
        // clear, it does not go away.
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func aGlassWindowViewTellsItsOwnWindow() {
        let window = aTitledWindow()
        window.contentView = NSHostingView(rootView: Text("content").glassWindow())
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }
}
