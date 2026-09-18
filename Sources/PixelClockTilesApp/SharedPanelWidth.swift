import Foundation
import SwiftUI

/// The width all three surfaces are drawn at, and the border each is dragged by.
///
/// One modifier rather than the same eight lines on the panel, the settings and
/// the History, and the reason is the defect this replaced: the width lived on
/// one surface and a literal `320` lived on the other two, so pressing the gear
/// narrowed the window under the pointer. Three copies of a rule are three
/// places for it to drift apart again. Here "they share a width" is structural —
/// there is one place that reads the key and one that writes it.
///
/// It carries the `.frame` as well as the border on purpose. A surface's width
/// and where that width can be dragged from are one decision, and splitting them
/// is how a surface ends up resizable at an edge that is not its own: applying
/// the border before the frame puts the grips on the content's bounds rather
/// than the surface's.
struct SharedPanelWidth: ViewModifier {
    /// Where the shared number is read and written.
    let defaults: UserDefaults

    /// A second axis for surfaces that have one, and nil for the two that do
    /// not. Only the History stores a height — see `HistoryHeight` — and the
    /// binding is the History's rather than this modifier's because the height
    /// is not shared: it belongs to the one surface with a list in it.
    let height: Binding<CGFloat>?

    /// Run after the width has been saved, so a surface with a second axis can
    /// persist that too. The default is the two surfaces with nothing else to
    /// say.
    let onEnded: () -> Void

    /// What a drag in flight has reached, and nil the rest of the time.
    ///
    /// Optional rather than a width held for the life of the view, because a
    /// held one goes stale: `MenuPanel` outlives the surface switch, so a width
    /// dragged on the settings would be saved and then come back to a panel
    /// still drawing the number it was built with. Nil means "ask the defaults",
    /// which is where the shared answer lives.
    ///
    /// It cannot be nil DURING a drag, and that is why the state exists at all:
    /// a `UserDefaults` write publishes nothing to SwiftUI, so a surface reading
    /// the defaults on every frame of a drag would draw the old width until
    /// something else happened to invalidate it — and during a drag nothing else
    /// happens.
    @State private var dragged: CGFloat?

    private var width: CGFloat { dragged ?? PanelWidth.stored(in: defaults).points }

    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .resizeBorder(
                // The setter is the point of building this by hand rather than
                // using `$dragged`: what a drag hands back is a raw number, and
                // it meets `PanelWidth` before it reaches the state. Bound
                // straight through, a drag would take the surface to twelve
                // points wide and only meet the floor when the button came up,
                // with nothing readable the whole way there.
                width: Binding(get: { width }, set: { dragged = PanelWidth($0).points }),
                height: height
            ) {
                // Saved, and only then let go of. The order is the whole
                // handover: the moment `dragged` is nil this is reading the
                // defaults again, so the defaults have to be holding the number
                // by then or the surface snaps back to what was there before the
                // drag.
                //
                // Written once the drag is over rather than on every change:
                // what reads it is the next launch and the other two surfaces,
                // and none of them is looking mid-drag. A menu bar surface
                // cannot be dismissed mid-drag either — what dismisses it is a
                // mouse-down elsewhere, and the mouse is already down here.
                PanelWidth(width).save(to: defaults)
                dragged = nil
                onEnded()
            }
    }
}

extension View {
    /// Draw this surface at the width the three of them share, and let any edge
    /// of it change that width.
    func panelWidth(
        from defaults: UserDefaults,
        alsoResizing height: Binding<CGFloat>? = nil,
        onEnded: @escaping () -> Void = {}
    ) -> some View {
        modifier(SharedPanelWidth(defaults: defaults, height: height, onEnded: onEnded))
    }
}
