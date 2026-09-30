import AppKit
import PixbarKit
import SwiftUI

@main
struct PixbarTilesApp: App {
    /// Adopted for one reason: a `MenuBarExtra` scene has no termination hook,
    /// and quit is where the held banner gets taken off the clock. `AppDelegate`
    /// is the only place that can ask macOS for the time to do it.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                model: delegate.model,
                panel: delegate.panelModel,
                settings: delegate.settingsModel,
                pin: delegate.panelPin,
                windowMoved: { delegate.panelMoved(to: $0) }
            )
        } label: {
            MenuBarGlyph(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        // The panel pinned to a window of its own. Floating while the app is
        // in the background, because a pinned panel that a text editor can
        // cover is a pin that did not take; normal while it is active, so the
        // app's own Settings can come in front of it
        // (`AppDelegate.levelThePinnedWindow`).
        Window("PixbarTiles", id: PinnedPanelWindow.id) {
            PinnedPanelWindow(
                model: delegate.model,
                panel: delegate.panelModel,
                settings: delegate.settingsModel,
                pin: delegate.panelPin
            )
        }
        .windowResizability(.contentSize)
        // Present at launch only when the pin was left in. Suppressed by
        // default an app would otherwise open a panel window nobody asked for;
        // suppressed ALWAYS, an app quit while pinned would come back saying
        // "pinned to its own window" with no window anywhere — a state the
        // user has to click their way out of.
        .defaultLaunchBehavior(delegate.panelPin.isPinned ? .presented : .suppressed)

        // The real Settings window — ⌘, opens it, the window is restorable,
        // and the panel's gear and every clock's gear aim it before opening.
        Settings {
            SettingsRoot(
                model: delegate.model,
                settings: delegate.settingsModel,
                discovery: delegate.discovery
            )
        }

        // The tile settings window: ONE window whose content swaps — the
        // second row asking re-targets the first's window, because ten open
        // tile windows is not a state worth supporting.
        Window("Tile Settings", id: "tile-settings") {
            TileSettingsWindow(
                model: delegate.model,
                settings: delegate.tileSettingsModel
            )
        }
        .windowResizability(.contentSize)
        // Opened at a size the content is comfortable at rather than at its
        // floor. Without one, macOS starts every `Window` scene at the
        // smallest size its content admits to, which for a two-column window
        // is both columns at their minimum and nothing to spare.
        .defaultSize(width: 720, height: 420)

        // The tile store: one window, re-aimed by whichever clock's gear
        // opened it. Choosing a tile is reading — categories and cards, not
        // a menu row.
        Window("Tile Store", id: "tile-store") {
            TileStoreWindow(store: delegate.storeModel)
        }
        .windowResizability(.contentSize)
        // Wide enough for three cards on the adaptive grid: at the floor it
        // is two, and a store whose shelf shows two things reads as a store
        // with two things on it.
        .defaultSize(width: 720, height: 480)

        // One clock's own settings: its tiles as cards, and the clock
        // itself. The facade carries the aim; a second gear's click
        // re-targets this one window.
        Window("Clock Settings", id: "clock-settings") {
            ClockSettingsWindow(
                settings: delegate.settingsModel,
                model: delegate.model,
                store: delegate.storeModel
            )
        }
        // The same resize rule as its two siblings. It was the one window
        // without it, so the three windows the app opens from a gear each
        // behaved differently when dragged.
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 460)
    }
}
