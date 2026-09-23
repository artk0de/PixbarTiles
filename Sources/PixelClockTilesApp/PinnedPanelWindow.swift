import PixelClockKit
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
            .glassWindow()
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
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: PinnedPanelWindow.id)
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
    }
}
