import AppKit
import SwiftUI

/// The menu bar mark.
///
/// A view of its own rather than an `Image` written inline, because a Scene does
/// not observe anything: the glyph would be drawn once at launch and never
/// change. A view does observe, so this is where the online state is read.
/// Internal rather than private so a test can draw it, and what is worth
/// drawing is the pair `AppGlyph`'s own tests cannot say: that the view picks
/// its image FROM the device state rather than from a constant, and that it
/// picks the right way round. The second half is not free — a render can only
/// report that two pictures differ, which `lit: !model.isDeviceOnline`
/// satisfies — so the test compares each render against the render of the
/// drawing that state is supposed to select, not against the other state.
struct MenuBarGlyph: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // No rendering mode on purpose. A template would let macOS tint the
        // ink for the bar, but it would tint the offline state's red square
        // with it — so the glyph is drawn per appearance instead.
        Image(nsImage: AppGlyph.menuBar(for: AppGlyph.state(
            hasNoClocks: model.hasNoClocks,
            isDeviceOnline: model.isDeviceOnline
        )))
    }
}

enum AppGlyph {
    /// 28x18, not square: the glyph's canvas in points, which is what
    /// `Scripts/MakeIcon.swift` emits at every scale — the menu bar caps an
    /// item's HEIGHT at the bar's, not its width. Read off `PixbarGlyph` so a
    /// size set here cannot disagree with the art and have macOS stretch it.
    static let menuBarSize = NSSize(width: PixbarGlyph.width, height: PixbarGlyph.height)

    /// Which of the two inks the bar is asking for.
    enum BarAppearance {
        case dark
        case light

        /// Read from the appearance AppKit is drawing WITH, not the app's or
        /// the system's: a status item follows the menu bar, which on recent
        /// macOS can follow the wallpaper and differ from both. `bestMatch`
        /// against the two concrete names IS the resolution — a light bar
        /// answers aqua, a dark one darkAqua — and inside a drawing handler
        /// `currentDrawing()` is the drawing view's own effective appearance.
        static func of(_ appearance: NSAppearance) -> BarAppearance {
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    /// One drawing of the mark: where the bundle keeps each appearance's
    /// variant, and what to draw when there is no bundle.
    ///
    /// A value holding all three names rather than conditionals inside
    /// `menuBar(lit:)`, and the reason is the defect this type shipped with.
    /// With the names picked separately, the mapping from state to drawing had
    /// no single site and nothing could read it back: swapping either pair
    /// inverted the menu bar and left the whole suite green, because every
    /// assertion in the suite said only that the two drawings DIFFER, which an
    /// inverted mapping satisfies exactly as well as a correct one. One value
    /// per state gives the direction somewhere to be asserted.
    struct Drawing: Equatable, Sendable {
        /// The PNG for a dark menu bar, in `Contents/Resources`, once
        /// `Scripts/bundle.sh` has assembled the .app.
        let darkResource: String
        /// The PNG for a light menu bar.
        let lightResource: String
        /// What an unbundled binary draws instead — which is every test, and a
        /// bare `swift run`. Symbols have no appearance variants; the shape is
        /// what the fallback is for.
        let symbol: String

        /// The variant drawn FOR the bar being drawn — the one place
        /// appearance and state meet.
        func resource(for appearance: BarAppearance) -> String {
            appearance == .dark ? darkResource : lightResource
        }
    }

    /// The screen lit: the case filled, the P and a hairline bezel knocked
    /// out of it. A clock is answering.
    static let litDrawing = Drawing(
        darkResource: "pixbar-glyph-dark-online",
        lightResource: "pixbar-glyph-light-online",
        symbol: "square.grid.3x2.fill"
    )

    /// The screen out: the case an outline, the P a half-point contour, a
    /// red square on the corner. No clock is answering. The outline is what
    /// still reads at 18pt; the red square is what says "fault" when it does.
    static let unlitDrawing = Drawing(
        darkResource: "pixbar-glyph-dark-offline",
        lightResource: "pixbar-glyph-light-offline",
        symbol: "square.grid.3x2"
    )

    /// The case with a blank screen: no clock has ever been configured, so
    /// there is nothing on it to show — no P, no badge, the case and feet
    /// whole.
    static let emptyDrawing = Drawing(
        darkResource: "pixbar-glyph-dark-empty",
        lightResource: "pixbar-glyph-light-empty",
        symbol: "rectangle"
    )

    /// Which of the three drawings the bar is showing.
    enum State: Equatable {
        case online, offline, empty
    }

    /// The state a glyph draws, from the two facts the model holds, decided
    /// once rather than at each caller. With no clocks configured the
    /// reachability question has nothing to be about — there is no clock to
    /// be answering or not — so the empty screen wins over both answers.
    static func state(hasNoClocks: Bool, isDeviceOnline: Bool) -> State {
        if hasNoClocks { return .empty }
        return isDeviceOnline ? .online : .offline
    }

    /// Which drawing a state selects.
    ///
    /// A function of its own, and the ONLY place the three are told apart.
    /// Inverting this table is the one edit that inverts the menu bar, so it
    /// is the one thing a test has to be able to read — which is what it could
    /// not do while the choice lived inside conditionals in the middle of an
    /// image lookup.
    static func drawing(for state: State) -> Drawing {
        switch state {
        case .online: litDrawing
        case .offline: unlitDrawing
        case .empty: emptyDrawing
        }
    }

    /// The menu bar mark: an image whose drawing handler picks the variant for
    /// whichever bar is drawing it, so the dark menu bar gets white ink and
    /// the light one black.
    ///
    /// A drawing handler rather than a resolved `NSImage`, and that is about
    /// time, not size: the bar's appearance is only known when AppKit draws,
    /// and it can change while the app runs. `cacheMode = .never` is what
    /// keeps nothing standing between AppKit's redraw and the handler, so a
    /// theme or wallpaper flip re-asks and the status item keeps up without
    /// any hook of ours.
    ///
    /// `NSImage(named:)` reads `Contents/Resources`, which only exists once
    /// `Scripts/bundle.sh` has assembled the .app — under a bare `swift run`
    /// there is no bundle and this returns nil. The SF Symbol fallback is what
    /// keeps the unbundled binary usable rather than showing an empty slot, and
    /// it is what the tests exercise: they run outside a bundle too.
    static func menuBar(for state: State) -> NSImage {
        let chosen = drawing(for: state)
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            let appearance = BarAppearance.of(NSAppearance.currentDrawing())
            // Force-unwrapped deliberately. The symbol ships with macOS 14, so
            // a nil here is a typo rather than a runtime condition — and the
            // alternative to failing loudly is a menu bar item with nothing in
            // it, which looks exactly like an app that did not launch.
            (NSImage(named: chosen.resource(for: appearance))
                ?? NSImage(
                    systemSymbolName: chosen.symbol, accessibilityDescription: "PixbarTiles"
                )!)
                .draw(in: rect)
            return true
        }
        // The default for a built image, said out loud because the old glyph's
        // whole preparation was the opposite: a template would discard the
        // offline red this glyph exists to carry.
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }
}
