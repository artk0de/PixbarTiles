import Foundation

/// How wide the panel was left, in points.
///
/// A value type whose initialiser clamps, rather than `@AppStorage` on the view.
/// `@AppStorage` hands the view whatever number is under the key — one typed by
/// hand with `defaults write`, one left behind by a build whose floor was
/// somewhere else, one a corrupt plist decoded to — and a menu bar panel handed
/// twelve points has nothing left to grab: the panel IS the window, so there is
/// no title bar to drag and no edge to find. Putting the rule in an initialiser
/// means no way of holding one of these went round it. It is also the half of
/// this feature that can be tested at all — a drag needs a window and an active
/// app, and a clamp needs neither — which is why the number the view draws with
/// comes through here rather than straight out of the defaults.
///
/// Width only, and the height is deliberately left to the content. Measured on
/// the running app: the panel's window is 198 points tall, the settings 615, and
/// the History however many jokes are in it. Each of those is its content's
/// fitting height, which SwiftUI re-imposes on every layout pass — a window set
/// by hand to 500x198 was back at 320x197 within half a second, and opening the
/// gear took it to 320x615 on its own. So a stored height would have to be one
/// per surface, and each would have to win a fight it loses; and there is no
/// scroll view anywhere here, so a height under the content clips it and a
/// height over it pads with nothing. Neither is a number worth asking somebody
/// to manage. The width is the one dimension the content does not already
/// decide, because `.frame(width:)` is what decides it — which is exactly why
/// this is the dimension that can be stored.
struct PanelWidth: Equatable, Sendable {
    /// What the three surfaces were laid out at, and what an app nobody has
    /// dragged opens at.
    static let designed: CGFloat = 320

    /// The floor, and it is the design width rather than something under it.
    ///
    /// Narrower is not a size this panel has ever been drawn at. The settings
    /// are a two-column form measured against 320 — the labels end at 104 and
    /// the fields are 292 wide — so the first thing lost on the way down is a
    /// surface the drag is not even on, and it is lost quietly. Since what was
    /// asked for is BIGGER, a floor at the design width costs nothing anybody
    /// wanted and removes a state nobody can get out of.
    static let smallest = designed

    /// The ceiling, and it is the same unrecoverable state from the other end.
    /// The panel hangs off its menu bar item, so width grows across the screen
    /// and takes the Quit button with it. 1280 points is the narrowest built-in
    /// display macOS 14 runs on — a 13-inch retina at its default scaling — and
    /// this keeps the far edge inside one.
    static let largest: CGFloat = 1_200

    static let storageKey = "panelWidth"

    /// Clamped. There is no way to build one of these that is not.
    let points: CGFloat

    init(_ points: CGFloat) {
        // Answered before the clamp rather than by it, because the clamp cannot:
        // `min(max(.nan, a), b)` is `.nan`, and `.frame(width: .nan)` is a panel
        // that does not lay out at all — an app that opens to nothing, with the
        // bad number still in the defaults so it opens to nothing again. Not
        // something `defaults write` produces on purpose, but `double(forKey:)`
        // hands back whatever a damaged plist decoded to.
        guard points.isFinite else {
            self.points = Self.designed
            return
        }
        self.points = min(max(points, Self.smallest), Self.largest)
    }

    /// What the last drag left, or the design width when nothing was ever
    /// dragged.
    ///
    /// The presence of the key is asked first, rather than reading
    /// `double(forKey:)` and trusting the answer, for the reason
    /// `QuietWindow.stored(in:)` asks the same way: `double(forKey:)` answers 0
    /// for a key that was never written, and 0 is a width. It happens to clamp
    /// to the same 320 the default gives, but only because the floor and the
    /// default are currently the same number — move the floor down and "never
    /// set" would silently start meaning "as narrow as allowed".
    static func stored(in defaults: UserDefaults) -> PanelWidth {
        guard defaults.object(forKey: storageKey) != nil else { return PanelWidth(designed) }
        // `double(forKey:)` and not a cast off `object(forKey:)`: the value may
        // have been written by this app as a double, or by a person as
        // `defaults write dev.artk0re.awtrix-connectors panelWidth -int 500`,
        // and a cast that only accepts one of those turns the other into a
        // silent reset to 320.
        return PanelWidth(defaults.double(forKey: storageKey))
    }

    /// Written as what the clamp produced, never as what the drag asked for.
    /// Reading it back would clamp it again, so this is not what makes it safe —
    /// what it buys is a defaults file that says what the app is actually doing,
    /// for whoever reads one when the panel is the wrong size.
    func save(to defaults: UserDefaults) {
        defaults.set(Double(points), forKey: Self.storageKey)
    }
}
