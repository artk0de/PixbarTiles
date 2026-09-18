import AppKit
import SwiftUI

/// One boundary of a surface, as somewhere a pointer can take hold of it.
///
/// Eight rather than one handle in a corner, because what was asked for is the
/// gesture every other window on the machine has: put the pointer on an edge and
/// pull. There is no native handle to hand over — a menu bar extra's window is
/// borderless and SwiftUI re-imposes its content's fitting size on it every
/// layout pass, measured in `834bd6a` — so the border has to be ours, and a
/// border is not a border if only one corner of it answers.
enum ResizeGrip: CaseIterable, Sendable {
    case leading, trailing, top, bottom
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Where the pointer has to travel, in SCREEN points, for this grip to make
    /// its surface bigger.
    ///
    /// Screen points, and that is the frame of reference the whole gesture is
    /// measured in: the panel hangs off its menu bar item, so an item near the
    /// right of the bar grows the window LEFTWARDS and moves the window's origin
    /// out from under the pointer. A translation reported in the window's own
    /// coordinates would read every point the window grew as another point the
    /// pointer had moved, and one nudge would run the size to the ceiling by
    /// itself. The screen is the one frame a resize does not move.
    ///
    /// `dy` is positive UPWARDS, because that is how `NSEvent.mouseLocation`
    /// reports it, and the surface grows DOWNWARDS from the menu bar — so the
    /// bottom edge's outward is negative and the top edge's is positive. This is
    /// the sign that reads backwards at a glance and it is why it is written
    /// down once, here, rather than at each of the four places that need it.
    var outward: CGVector {
        switch self {
        case .leading: CGVector(dx: -1, dy: 0)
        case .trailing: CGVector(dx: 1, dy: 0)
        case .top: CGVector(dx: 0, dy: 1)
        case .bottom: CGVector(dx: 0, dy: -1)
        case .topLeading: CGVector(dx: -1, dy: 1)
        case .topTrailing: CGVector(dx: 1, dy: 1)
        case .bottomLeading: CGVector(dx: -1, dy: -1)
        case .bottomTrailing: CGVector(dx: 1, dy: -1)
        }
    }

    /// The size a drag reaches, given where it started and how far the pointer
    /// has come since.
    ///
    /// Computed from the size at drag START rather than accumulated frame by
    /// frame, so a drag that ran into a floor and came back gives the size back.
    /// Accumulating would leave the pointer somewhere the surface is not, and
    /// the floor is reached often — it is 320, which is where every drag starts.
    ///
    /// Unclamped, deliberately. What the limits are is a question about the
    /// surface — the settings form's two columns, the History against the height
    /// of the screen — and this type knows about neither. The callers hand the
    /// answer through `PanelWidth` and `HistoryHeight`, which is where every
    /// other way of setting a size meets the same rule.
    func size(from start: CGSize, movedBy moved: CGVector) -> CGSize {
        CGSize(
            width: start.width + outward.dx * moved.dx,
            height: start.height + outward.dy * moved.dy
        )
    }

    var resizesWidth: Bool { outward.dx != 0 }
    var resizesHeight: Bool { outward.dy != 0 }

    /// A corner is the two edges that meet at it, so it is the grip that moves
    /// both axes.
    var isCorner: Bool { resizesWidth && resizesHeight }

    /// Where on the surface this grip sits, which is the same fact as `outward`
    /// read as a place instead of a direction.
    var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    /// What the pointer becomes over this grip.
    ///
    /// The border has no ink — it sits over the surface's own padding — so the
    /// cursor is the entire affordance, and the requirement is that it says what
    /// the edge does BEFORE it is pressed. A border that resizes without saying
    /// so is indistinguishable from one that does nothing.
    @MainActor var cursor: NSCursor {
        switch (resizesWidth, resizesHeight) {
        case (true, false): .resizeLeftRight
        case (false, true): .resizeUpDown
        default: Self.diagonal(at: self)
        }
    }

    /// The corner cursor, or the nearest honest thing on macOS 14.
    ///
    /// AppKit had no public diagonal resize cursor until
    /// `frameResize(position:directions:)` in macOS 15. The one the window
    /// server draws at a window's corner is `_windowResizeNorthWestSouthEast`,
    /// which is private and not something to ship. So on 14 a corner says the
    /// horizontal axis rather than saying nothing: the corner does move both,
    /// and half a truth beats an arrow that denies the border exists.
    ///
    /// Leading and trailing are read as left and right here. Under a
    /// right-to-left layout SwiftUI would place these grips the other way round
    /// and the corner cursor would name the wrong side — cosmetic, and this app
    /// has no RTL localisation to reach it.
    @MainActor private static func diagonal(at grip: ResizeGrip) -> NSCursor {
        guard #available(macOS 15.0, *) else { return .resizeLeftRight }
        let position: NSCursor.FrameResizePosition = switch grip {
        case .topLeading: .topLeft
        case .topTrailing: .topRight
        case .bottomLeading: .bottomLeft
        default: .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }
}

/// The whole border of a surface, as somewhere to drag it from.
///
/// An overlay rather than a frame round the content, so adding it costs the
/// surface no size: the grips sit ON the surface's own 14 points of padding,
/// which is the one band of it where nothing is drawn and nothing is clickable.
/// A border that took space of its own would have moved every row inwards to buy
/// an affordance that is invisible anyway.
///
/// What it does NOT do is decide how big a surface may be. It reports a size and
/// the caller clamps, because the limits belong to the surface — see
/// `ResizeGrip.size(from:movedBy:)`.
struct ResizeBorder: ViewModifier {
    /// How deep the grabbable band is.
    ///
    /// Six points against the surface's fourteen of padding, so a grip never
    /// reaches a control: the leftmost thing on any row — the Quit button, a
    /// slider, a text field — starts at fourteen. macOS gives its own windows
    /// about five, so this is also roughly the depth a hand already expects.
    static let thickness: CGFloat = 6

    /// The width the surface is drawn at, and where a drag on a vertical edge
    /// writes. The setter is where the caller's clamp lives.
    @Binding var width: CGFloat

    /// The height, or nil on a surface whose height is its content's.
    ///
    /// Nil is not "a height of zero": it decides whether the horizontal edges
    /// and the corners are drawn at all. A top edge on the panel would be a
    /// region that shows a resize cursor and then resizes nothing, which is the
    /// same lie as a border that resizes silently, told from the other side.
    let height: Binding<CGFloat>?

    /// Called when the button comes up, so the caller can persist what it has.
    let onEnded: () -> Void

    /// The size and the pointer as they were when the drag began, or nil between
    /// drags. One value for all eight grips, because there is one pointer: half
    /// a drag on two edges at once is not a state this can be in.
    @State private var start: (size: CGSize, pointer: CGPoint)?

    /// Which grips a surface offers, given whether it has a height to change.
    static func grips(resizingHeight: Bool) -> [ResizeGrip] {
        resizingHeight ? ResizeGrip.allCases : [.leading, .trailing]
    }

    func body(content: Content) -> some View {
        content.overlay {
            ForEach(Self.grips(resizingHeight: resizesHeight), id: \.self) { grip in
                // Each band is given the whole surface to sit in and put where
                // it belongs by alignment, rather than by an `.overlay` apiece.
                // One list means one place that decides which grips exist — a
                // per-grip overlay would have needed the same "has it a height"
                // question asked again at each of the eight.
                band(grip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: grip.alignment)
            }
        }
    }

    private var resizesHeight: Bool { height != nil }

    /// The strip of surface this grip answers to.
    ///
    /// The padding sits outside the frame in each chain on purpose: there it is
    /// subtracted from the size SwiftUI proposes rather than added to the size
    /// taken, so an edge ends where the corner begins instead of overflowing the
    /// surface by a corner at each end. On a surface with no corners the edges
    /// run its full height, so there is no dead spot to find at the ends.
    @ViewBuilder
    private func band(_ grip: ResizeGrip) -> some View {
        if grip.isCorner {
            region(grip).frame(width: Self.thickness, height: Self.thickness)
        } else if grip.resizesWidth {
            region(grip)
                .frame(width: Self.thickness)
                .frame(maxHeight: .infinity)
                .padding(.vertical, resizesHeight ? Self.thickness : 0)
        } else {
            region(grip)
                .frame(height: Self.thickness)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.thickness)
        }
    }

    private func region(_ grip: ResizeGrip) -> some View {
        Color.clear
            // Clear has no ink, and a hit area is the ink unless it is told
            // otherwise.
            .contentShape(Rectangle())
            // Set rather than pushed and popped. A menu bar panel is dismissed
            // by a click somewhere else, which can perfectly well land while the
            // pointer is over a grip — and a view torn down mid-hover never gets
            // its `false`. A push left unbalanced follows the user into the next
            // app as a resize cursor nothing will take back.
            .onHover { inside in
                if inside { grip.cursor.set() } else { NSCursor.arrow.set() }
            }
            .gesture(drag(grip))
            // Eight invisible regions that only a pointer can work are eight
            // elements VoiceOver would read out and none it could use. macOS
            // does not expose a window's own resize border either.
            .accessibilityHidden(true)
    }

    private func drag(_ grip: ResizeGrip) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                let pointer = NSEvent.mouseLocation
                let origin = start
                    ?? (size: CGSize(width: width, height: height?.wrappedValue ?? 0),
                        pointer: pointer)
                start = origin
                let moved = CGVector(
                    dx: pointer.x - origin.pointer.x,
                    dy: pointer.y - origin.pointer.y
                )
                let reached = grip.size(from: origin.size, movedBy: moved)
                // Only the axes this grip owns are written back. Assigning both
                // would push the untouched one through the caller's clamp on
                // every frame, and a height that has never been set would arrive
                // at the History as a real number the first time somebody
                // widened it.
                if grip.resizesWidth { width = reached.width }
                if grip.resizesHeight { height?.wrappedValue = reached.height }
            }
            .onEnded { _ in
                start = nil
                onEnded()
            }
    }
}

extension View {
    /// Thin drag regions on every edge and corner of this surface.
    ///
    /// Applied AFTER the `.frame` that sets the size, or the border lands on the
    /// content's own bounds and leaves the surface's edge — the part a hand goes
    /// for — outside it.
    func resizeBorder(
        width: Binding<CGFloat>,
        height: Binding<CGFloat>? = nil,
        onEnded: @escaping () -> Void
    ) -> some View {
        modifier(ResizeBorder(width: width, height: height, onEnded: onEnded))
    }
}
