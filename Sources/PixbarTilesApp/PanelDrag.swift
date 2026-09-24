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

    static func bringOnly(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: activation)
    }
}
