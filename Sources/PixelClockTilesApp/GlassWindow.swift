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
    func glassWindow() -> some View {
        modifier(GlassWindowModifier())
    }
}

private struct GlassWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Fill first: a window the user has dragged bigger than its
            // content is where a content-shaped material shows its seams.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.regularMaterial, for: .window)
            // The titlebar is the window's too. `containerBackground` paints
            // the content, and the titlebar kept an opaque band of its own
            // over it — a dark strip across the top of a material window.
            // Only the window can be told to drop it, so the view asks the
            // window it lands on.
            .background(
                WindowReader { $0?.adoptGlassTitlebar() }
                    .allowsHitTesting(false)
            )
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

    /// Lets the window's material show through its titlebar.
    ///
    /// Transparent, so the titlebar stops painting its own band; full-size
    /// content, so there is material under it to show. The traffic lights and
    /// the title stay where they are, and SwiftUI's safe area keeps the
    /// content's controls out from under them.
    func adoptGlassTitlebar() {
        titlebarAppearsTransparent = true
        styleMask.insert(.fullSizeContentView)
    }
}
