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
                    }
                    WindowFocus.bringOnly(window)
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

/// What the menu bar item shows while the panel is pinned.
///
/// Not the panel again: two live copies of one surface is a reader deciding
/// which is the real one. The item stays in the menu bar because it is the way
/// back — the window may be behind everything, or on another Space.
struct PinnedElsewherePanel: View {
    let pin: PanelPin

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PixelArt(
                    map: PanelGlyph.pin,
                    palette: PanelGlyph.pinPalette(pinned: true, ink: PanelGlyph.pinnedTint)
                )
                Wordmark()
            }
            Text("Pinned to its own window.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Bring it forward") {
                    openWindow(id: PinnedPanelWindow.id)
                    focusThePinnedWindow()
                }
                .buttonStyle(.glass)
                Button("Unpin") {
                    pin.set(false)
                    dismissWindow(id: PinnedPanelWindow.id)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(width: 240)
        // Opening is how a DRAG becomes a window: the pin flips in the
        // delegate, this content replaces the panel, and there is nowhere
        // else with an `openWindow` to call. After a drag the popover it came
        // from closes — the window, where the drag let go, is the one panel
        // on screen, and it takes the focus alone. Opened from the menu bar
        // item instead, the popover stays: it is where Unpin is.
        .task {
            AppLog.panel.info("pinned-elsewhere content appeared — opening the window")
            let fromADrag = pin.isDetaching
            openWindow(id: PinnedPanelWindow.id)
            if fromADrag {
                dismiss()
            } else {
                focusThePinnedWindow()
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func focusThePinnedWindow() {
        guard let window = WindowFocus.pinnedWindow(among: NSApp.windows) else { return }
        WindowFocus.bringOnly(window)
    }
}
