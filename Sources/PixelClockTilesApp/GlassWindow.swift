import AppKit
import SwiftUI

/// The material a window is made of.
///
/// One modifier, one mechanism, every window — the app had three before this
/// and they disagreed about how much of a window the material covers.
///
/// **What was wrong.** The material was drawn with `.glassEffect(in:)` on the
/// CONTENT, over a window whose background had been cleared by an
/// `NSViewRepresentable` reaching for its own `NSWindow`. Glass drawn that way
/// is the shape of the content's bounds: the titlebar band above it, and every
/// margin the content does not lay out into once the window is resized past
/// its ideal size, were left with a cleared background and nothing painted on
/// it. That is the "the material is only part of the window" the user reported
/// — it was literally true, and the cleared background is what made the
/// remainder read as a hole rather than as an ordinary window.
///
/// **What it does now.** `containerBackground(_:for: .window)` hands the
/// material to the WINDOW, which is whose it is: AppKit paints it across the
/// whole frame, under the titlebar, and keeps painting it while the window is
/// resized. Nothing clears a background and nothing measures the content, so
/// there is no second answer to be wrong. The content is stretched to fill so
/// a small view in a large window leaves material rather than a void.
extension View {
    /// This window's material. The content keeps its own backgrounds where it
    /// has them; the material reads at the edges, behind every gap, and under
    /// the titlebar.
    ///
    /// `fill` is for windows the user RESIZES — the settings, a tile's — where
    /// content dragged smaller than its window would otherwise leave the
    /// material a content-shaped patch. A window sized to its content wants
    /// the opposite: under `.windowResizability(.contentSize)` a fill to
    /// infinity IS the content size, and the window opens as wide as the
    /// screen with the panel laid out at its own width in the corner.
    func glassWindow(fill: Bool = true) -> some View {
        modifier(GlassWindowModifier(fill: fill))
    }
}

private struct GlassWindowModifier: ViewModifier {
    let fill: Bool

    func body(content: Content) -> some View {
        content
            // Fill first: a window the user has dragged bigger than its
            // content is where a content-shaped material shows its seams.
            .frame(
                maxWidth: fill ? .infinity : nil,
                maxHeight: fill ? .infinity : nil,
                alignment: .topLeading
            )
            .containerBackground(.regularMaterial, for: .window)
            // The titlebar is the window's too. The dark band across the top
            // of a material window is the SCENE's toolbar background, which
            // SwiftUI draws over the titlebar whether or not the window has a
            // toolbar. Hidden, the container background shows through it —
            // Apple's own recipe for a material window (WWDC24, "Tailor macOS
            // windows with SwiftUI"). An AppKit `titlebarAppearsTransparent`
            // was tried first and changed nothing: the band is not AppKit's.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Lays the navigation layer's material on a TRANSIENT surface — the menu bar
/// panel, which is not a `Window` scene and has no container background to
/// hand a material to.
///
/// Separate from `glassWindow()` and deliberately so: the panel's window is
/// built by `MenuBarExtra` itself, cannot be reached by a scene modifier, and
/// is cleared by the delegate that learns about it. This is the one place in
/// the app where the material is drawn as a shape, because it is the one
/// surface whose shape IS the material's.
extension View {
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension NSWindow {
    /// Clears a window's own background, once.
    ///
    /// The panel's window needs it: `glassEffect` refracts whatever is behind
    /// the window, and behind an opaque background there is nothing — the
    /// material renders as a dark slab. Written here rather than at the two
    /// call sites that each had their own copy of these three lines.
    func clearBackgroundForGlass() {
        guard isOpaque else { return }
        isOpaque = false
        backgroundColor = .clear
    }
}
