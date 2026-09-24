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
/// Width only, and it is the width of all three surfaces — the panel, the
/// settings and the History read this one key, so the window does not change
/// size when somebody presses the gear.
///
/// Height is not here, and only ONE surface has one at all: see `HistoryHeight`
/// below. Measured on the running app, the panel's window is 198 points tall and
/// the settings 615, each of them its content's fitting height, which SwiftUI
/// re-imposes on every layout pass — a window set by hand to 500x198 was back at
/// 320x197 within half a second, and opening the gear took it to 320x615 on its
/// own. A stored height for either would be a number fighting the content for no
/// gain: under it, it clips a form nothing scrolls; over it, it pads with
/// nothing. What makes the History different is the `ScrollView` in it, which is
/// what turns a height from a clip into a viewport.
///
/// So the rule is not "width can be stored and height cannot". It is that a
/// dimension can be stored where the content does not already decide it — the
/// width, because `.frame(width:)` is what decides it, and the History's list,
/// because a scroll view takes whatever height it is given.
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
    /// `StoredLocation` asks the same way: `double(forKey:)` answers 0
    /// for a key that was never written, and 0 is a width. It happens to clamp
    /// to the same 320 the default gives, but only because the floor and the
    /// default are currently the same number — move the floor down and "never
    /// set" would silently start meaning "as narrow as allowed".
    static func stored(in defaults: UserDefaults) -> PanelWidth {
        guard defaults.object(forKey: storageKey) != nil else { return PanelWidth(designed) }
        // `double(forKey:)` and not a cast off `object(forKey:)`: the value may
        // have been written by this app as a double, or by a person as
        // `defaults write dev.artk0re.pixelclocktiles panelWidth -int 500`,
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

/// How tall the History's list was left, in points.
///
/// The same shape as `PanelWidth` and in the same file, because it is the same
/// rule on the other axis and the two arguments only make sense beside each
/// other: what can be stored is what the content does not already decide.
///
/// Only the History has one. It is the surface holding a list that outgrows any
/// height — ten days of a half-hourly connector is a few hundred entries — and
/// the only one with a `ScrollView`, which is what makes a height a viewport
/// rather than a pair of scissors. The panel and the settings are exactly as
/// tall as their rows and have nothing to gain from a number somebody has to
/// manage.
///
/// What it measures is the LIST, not the surface: it replaces the
/// `.frame(maxHeight: 280)` the entries carried, so the surface comes to this
/// plus its header and padding. That is why the ceiling has to leave room for
/// them.
struct HistoryHeight: Equatable, Sendable {
    /// What the list was capped at before anybody could change it, and what an
    /// app nobody has dragged opens at.
    static let designed: CGFloat = 280

    /// The floor. Two entries and the edge to grab them back by.
    ///
    /// Same rule as `PanelWidth.smallest` and the same reason: a menu bar
    /// surface IS its window, so a list dragged to nothing leaves no bottom edge
    /// to pull and no title bar to fall back on, and the only way out is
    /// `defaults delete`. A row is a three-line joke over a pair of buttons,
    /// about 65 points, so this is two of them.
    static let smallest: CGFloat = 140

    /// What the History's own chrome takes before the list gets any.
    ///
    /// Measured on the laid-out surface rather than guessed: 69 points for the
    /// 28 of padding, the header, the divider and the spacing between them, and
    /// about 115 once a failed replay has put its two-line answer under the
    /// title. Rounded UP from the worst of those, because being wrong in this
    /// direction costs a few points of list, and being wrong in the other puts
    /// the bottom of the History under the bottom of the display — where the
    /// edge that would drag it back has gone too, and scrolling cannot help
    /// because it is the viewport that is off the screen.
    static let chrome: CGFloat = 120

    /// Stood in for the screen when there is no screen to ask.
    ///
    /// `NSScreen.main` is nil with no display attached, which is a machine
    /// nobody is looking at — so this only has to be safe, not right. 800 points
    /// is the shortest built-in display macOS 14 runs on, a 13-inch at its
    /// default scaling, so a History clamped against it fits on anything.
    static let shortestDisplay: CGFloat = 800

    static let storageKey = "historyHeight"

    /// The tallest list this screen has room for.
    ///
    /// A question about the SCREEN rather than about the History, which is why
    /// it is a function and not a constant the way `PanelWidth.largest` is. The
    /// width could take a fixed ceiling because it grows sideways off a menu bar
    /// item and 1200 fits the narrowest display; a height hangs from the menu
    /// bar downwards, so how much there is depends entirely on what is below it.
    ///
    /// Floored at `smallest`, because on a short enough screen the ceiling drops
    /// below the floor and a plain `min(max(…))` would then hand back the
    /// CEILING — the unrecoverable surface, produced by the guard against it. A
    /// History that overhangs a very short screen is the lesser of the two: the
    /// header and the back button are at the top, which is the end that stays on
    /// the display.
    static func largest(fittingInto screenHeight: CGFloat) -> CGFloat {
        max(smallest, screenHeight - chrome)
    }

    /// Clamped, against this screen. There is no way to build one that is not.
    let points: CGFloat

    /// The screen is required rather than defaulted, and that is deliberate:
    /// every way of arriving at a height has to say what it must fit inside, so
    /// none of them can quietly skip the part that keeps the surface reachable.
    init(_ points: CGFloat, fittingInto screenHeight: CGFloat) {
        // Answered before the clamp rather than by it, for the reason
        // `PanelWidth` answers it first: `min(max(.nan, a), b)` is `.nan`, and a
        // list framed at `.nan` does not lay out at all — with the bad number
        // still stored, so it opens to nothing again next time. The design
        // height still has to meet the screen, or a damaged plist on a small
        // display would be answered with 280 the display has no room for.
        guard points.isFinite else {
            self.points = min(Self.designed, Self.largest(fittingInto: screenHeight))
            return
        }
        self.points = min(
            max(points, Self.smallest), Self.largest(fittingInto: screenHeight)
        )
    }

    /// What the last drag left, or the height the list was capped at when
    /// nothing was ever dragged.
    ///
    /// Clamped on the way out as much as on the way in, and here that is not
    /// only about hand-typed values: a height saved on a 27-inch display is read
    /// again on the laptop it was closed onto, and the screen it has to fit is
    /// the one in front of the user now.
    static func stored(in defaults: UserDefaults, fittingInto screenHeight: CGFloat) -> HistoryHeight {
        guard defaults.object(forKey: storageKey) != nil else {
            return HistoryHeight(designed, fittingInto: screenHeight)
        }
        // `double(forKey:)` and not a cast off `object(forKey:)`, for the reason
        // `PanelWidth.stored(in:)` reads it that way: the value may have been
        // written by this app as a double or by a person as
        // `defaults write dev.artk0re.pixelclocktiles historyHeight -int 280`,
        // and a cast that accepts only one turns the other into a silent reset.
        return HistoryHeight(defaults.double(forKey: storageKey), fittingInto: screenHeight)
    }

    /// Written as what the clamp produced, never as what the drag asked for.
    func save(to defaults: UserDefaults) {
        defaults.set(Double(points), forKey: Self.storageKey)
    }
}
