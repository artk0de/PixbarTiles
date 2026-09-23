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

    func toggle() { set(isPinned == false) }

    func set(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        defaults.set(pinned, forKey: Self.key)
    }
}
