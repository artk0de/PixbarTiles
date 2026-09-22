import AppKit
import SwiftUI

/// Liquid Glass for a whole window: clears the window's own background —
/// behind an opaque background there is nothing for the material to
/// refract, and it renders as a dark slab — and lays the content on the
/// glass in one shape.
///
/// The clear is done from inside, by a view that is given its window, for
/// the same reason the panel's reader exists: a SwiftUI scene cannot reach
/// its `NSWindow`, but a view in the content can.
extension View {
    /// The window's material. The content keeps its own backgrounds where it
    /// has them; the glass reads at the edges and behind every gap.
    func glassWindow(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassWindowModifier(cornerRadius: cornerRadius))
    }
}

private struct GlassWindowModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(WindowBackgroundClearer().allowsHitTesting(false))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Clears the background of whatever window this view lands on — once per
/// window, and only while it is still opaque.
private struct WindowBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingView() }

    func updateNSView(_ view: NSView, context: Context) {}

    /// Reports its window the moment AppKit puts it on one — the same hook
    /// the panel's reader uses.
    private final class ClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.isOpaque else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
