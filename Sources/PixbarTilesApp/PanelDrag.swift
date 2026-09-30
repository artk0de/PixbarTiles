import AppKit

/// Drag-to-pin, as a gesture with an end: the popover's moves are followed
/// while a button is down, and the pin lands where the drag is let go.
///
/// Pinning on the first move opened the pinned window where the drag BEGAN
/// while the user went on dragging the popover somewhere else — two copies of
/// the panel on screen, neither where it was put.
///
/// AppKit runs a window drag in its own tracking loop, so the mouse-up never
/// reaches the app as an event; the delegate asks `released` on a short timer
/// instead, reading the button state the way `panelWasDragged` always has.
struct PanelDrag {
    /// Where the popover's top-left corner is, while a drag is under way.
    private var pending: CGPoint?

    /// The popover moved. Answers whether a drag is now being followed — the
    /// caller's cue to start asking `released`. A move with no button down is
    /// macOS placing the popover under the menu bar item, not a drag; a move
    /// of a pinned panel has nothing left to pin.
    mutating func moved(topLeft: CGPoint, buttonDown: Bool, pinned: Bool) -> Bool {
        guard buttonDown, pinned == false else { return false }
        pending = topLeft
        return true
    }

    /// Where to pin, once, when the drag is over; nil while it goes on or
    /// when there was none.
    mutating func released(buttonDown: Bool) -> CGPoint? {
        guard buttonDown == false, let origin = pending else { return nil }
        pending = nil
        return origin
    }
}

/// Bringing the pinned window forward and nothing else.
///
/// `NSApp.activate(ignoringOtherApps:)` raises every window the app has: a
/// drag-to-pin brought Settings, the store and a clock's settings up over the
/// user's work along with the panel. Activating with no options brings the
/// key and main windows forward, and the pinned window is made both first.
@MainActor
enum WindowFocus {
    static let activation: NSApplication.ActivationOptions = []

    /// The pinned panel's window: SwiftUI names a `Window` scene's window
    /// after the scene's id.
    static func pinnedWindow(among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue.hasPrefix(PinnedPanelWindow.id) == true }
    }

    /// Activation is asked for the polite way first — key and main windows
    /// only. macOS refuses it more often than not from a menu bar click
    /// (measured: `activated=false` on most clicks, the window left
    /// inactive, translucent, and on a Space the user was not taken to), so
    /// the refusal falls back to the call this app has always been granted.
    static func bringOnly(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        var activated = NSRunningApplication.current.activate(options: activation)
        if activated == false {
            NSApp.activate(ignoringOtherApps: true)
            activated = NSApp.isActive
        }
        window.makeKeyAndOrderFront(nil)
        AppLog.panel.info(
            """
            focus pinned window: activated=\(activated, privacy: .public) \
            key=\(window.isKeyWindow, privacy: .public) \
            screen=\(String(describing: window.screen?.localizedName), privacy: .public) \
            frame=\(String(describing: window.frame), privacy: .public)
            """
        )
    }

    /// Brings the app forward for a window just opened from the panel — a
    /// clock's settings, a tile's, the store. The polite activation first;
    /// refused (most clicks from the menu bar are), the forced one, or the
    /// window opens inactive under the panel that asked for it.
    static func activate(
        polite: () -> Bool = { NSRunningApplication.current.activate(options: activation) },
        force: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    ) {
        if polite() == false { force() }
    }

    /// Takes the popover away once it has opened a window. It lives at the
    /// menu bar's level, above every ordinary window, and does not close when
    /// the key goes to another window of this app — left up, it covered the
    /// clock's settings it had just opened. A pinned panel is a window the
    /// user put there, and stays.
    static func stepAside(_ panel: NSWindow?, pinned: Bool) {
        guard !pinned else { return }
        panel?.orderOut(nil)
    }

    /// Closes the pinned window. The unpin button sits INSIDE that window,
    /// and a SwiftUI `dismissWindow` from there left it open beside the
    /// popover — two panels again.
    static func closePinned(among windows: [NSWindow]) {
        pinnedWindow(among: windows)?.close()
    }

    /// The pinned window floats over other apps, so a text editor cannot bury
    /// it — and only over them: while this app is active, its Settings and a
    /// clock's settings must be able to come in front of it.
    static func pinnedLevel(appIsActive: Bool) -> NSWindow.Level {
        appIsActive ? .normal : .floating
    }
}
