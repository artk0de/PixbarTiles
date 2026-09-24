import SwiftUI

/// What the menu bar item's popover holds: the panel, or — while the panel is
/// pinned to a window of its own — nothing to see (`PinnedElsewherePanel`).
///
/// A view rather than an `if` in the Scene's body, because a Scene observes
/// nothing: switched there, the popover kept the pinned-elsewhere content
/// after an unpin, and every click on the item reopened the old pinned window
/// where it had been left.
struct MenuBarContent: View {
    let model: AppModel
    let panel: PanelModel
    let settings: SettingsModel
    let pin: PanelPin
    /// Told which window the popover is on, for the delegate's watchers.
    let windowMoved: (NSWindow?) -> Void

    var body: some View {
        if pin.isPinned {
            PinnedElsewherePanel(pin: pin)
        } else {
            MenuPanel(model: model, panel: panel, settings: settings, pin: pin)
                // The panel's material, laid on here rather than inside the
                // view: Liquid Glass is the navigation layer's own, and a view
                // that carried it could not be drawn without it — every pixel
                // test draws this content straight.
                .glassPanel()
                // Behind the panel rather than inside `MenuPanel`, because it
                // is not the panel's business which window it is on — it is
                // the delegate's.
                //
                // Taken out of hit testing, because an `NSView` is in it by
                // default: this one is laid out across the whole panel and
                // answers no click, so anywhere the panel does not draw a
                // control it would be what the click reached.
                .background(
                    PanelWindowReader { windowMoved($0) }
                        .allowsHitTesting(false)
                )
        }
    }
}
