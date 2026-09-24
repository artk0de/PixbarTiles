import PixbarKit
import SwiftUI

/// The panel, pinned to a window of its own.
///
/// The same `MenuPanel` the menu bar item shows — one surface, two hosts, as
/// `HistoryList` already is. What the window adds is the thing the pin is for:
/// it is a window, so losing focus does not take it away.
///
/// A window rather than a popover that refuses to close, because a
/// `MenuBarExtra(.window)` is dismissed by macOS and the app only hears about
/// it afterwards (`AppDelegate.watchThePanelsWindow` observes; it does not
/// decide). There is nothing there to suppress.
struct PinnedPanelWindow: View {
    static let id = "pinned-panel"

    @ObservedObject var model: AppModel
    let panel: PanelModel
    let settings: SettingsModel
    let pin: PanelPin

    var body: some View {
        MenuPanel(model: model, panel: panel, settings: settings, pin: pin)
            // Not filled: this window is sized to the panel, so a fill to
            // infinity would be the size it opened at — the panel laid out at
            // its own width in the corner of a screen-wide window.
            .glassWindow(fill: false)
            // Placed where the drag let it go, when a drag is what opened it.
            // A window that pins itself and then appears in the middle of the
            // screen is a move the user has to make twice. However it opened,
            // it takes the focus alone: the app's other windows stay put.
            .background(
                PanelWindowReader { window in
                    guard let window else { return }
                    if let origin = pin.takeDetachedOrigin() {
                        window.setFrameTopLeftPoint(origin)
                        // Again a turn later: SwiftUI places a Window scene's
                        // window after it appears (measured: dropped at 759,
                        // found at 798 50 ms on), and the drop point is the
                        // one the user chose.
                        DispatchQueue.main.async { window.setFrameTopLeftPoint(origin) }
                    }
                    WindowFocus.bringOnly(window)
                    window.level = WindowFocus.pinnedLevel(appIsActive: NSApp.isActive)
                }
                .allowsHitTesting(false)
            )
            // The pin comes out when the window is closed by its own red
            // button too. Otherwise the app would remember a pin whose window
            // is gone, and the next launch would open a window nobody asked
            // for.
            .onDisappear { pin.set(false) }
    }
}

/// What the menu bar item's popover holds while the panel is pinned: nothing
/// to see. The item is only the way back to the window — a click focuses it
/// (`AppDelegate.panelDidOpen`), and the focus moving away is what dismisses
/// this popover. A card saying "pinned to its own window" was one more window
/// between the user and the one they asked for; unpinning is the window's own
/// pin, or its close button.
///
/// Its one job is the drag: the pin flips in the delegate, this content
/// replaces the panel, and there is nowhere else with an `openWindow` to call.
struct PinnedElsewherePanel: View {
    let pin: PanelPin

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            // The popover goes FIRST: while it is open the app has a window
            // on the current Space — over a full-screen app, that Space — and
            // macOS has no reason to take the user to the Space the pinned
            // window is on. Then the window is opened (opening one already
            // open raises it) and focused a turn later, so the popover's own
            // closing does not take the focus back.
            .task {
                guard pin.isPinned else { return }
                AppLog.panel.info("pinned-elsewhere content appeared — opening the window")
                dismiss()
                await Task.yield()
                openWindow(id: PinnedPanelWindow.id)
                await Task.yield()
                if let window = WindowFocus.pinnedWindow(among: NSApp.windows) {
                    WindowFocus.bringOnly(window)
                }
            }
    }
}
