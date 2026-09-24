import Foundation
import Observation

/// Whether the panel is pinned to a window of its own.
///
/// The panel is a `MenuBarExtra(.window)`, and macOS — not this app — closes it
/// when it stops being key. `AppDelegate.watchThePanelsWindow` only OBSERVES
/// that dismissal; there is nothing to suppress. So a pin cannot mean "keep the
/// popover up": it means the content moves to a real `Window` scene, floating,
/// which stays because it is a window. Unpinning closes it and the menu bar
/// item goes back to being the way in.
///
/// Persisted, because this is the one panel state that must outlive the panel.
/// A pin the app forgets at relaunch is a pin somebody sets every morning.
@MainActor
@Observable
final class PanelPin {
    private static let key = "panelPinnedToItsOwnWindow"

    /// Handed in rather than reached for, so a test can put a pin in a store of
    /// its own instead of in the preferences of whoever runs the suite.
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var isPinned: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPinned = defaults.bool(forKey: Self.key)
    }

    /// Where the popover was when the user dragged it, or nil once that has
    /// been used. Not persisted: it describes one gesture, and a gesture does
    /// not outlive the launch it happened in. The pin does.
    private var detachedOrigin: CGPoint?

    /// The panel was dragged off the menu bar: pin it, and remember where it
    /// was let go. A window that pins itself and then opens in the middle of
    /// the screen is a move the user has to make twice.
    func detach(at origin: CGPoint) {
        detachedOrigin = origin
        set(true)
    }

    /// Whether a drag has just pinned the panel and its window has not opened
    /// yet — the popover the drag came from is then to be closed, not shown.
    var isDetaching: Bool { detachedOrigin != nil }

    /// The detach origin, once. Left behind, the next pin would drag the
    /// window back to wherever the last detach happened to land.
    func takeDetachedOrigin() -> CGPoint? {
        defer { detachedOrigin = nil }
        return detachedOrigin
    }

    func toggle() { set(isPinned == false) }

    func set(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        defaults.set(pinned, forKey: Self.key)
    }
}
