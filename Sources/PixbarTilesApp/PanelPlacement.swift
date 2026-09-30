import AppKit
import Observation

/// Where the panel hangs: to the RIGHT of its menu bar item, its left edge
/// under the item's.
///
/// macOS places a `MenuBarExtra` window by itself, and a window wider than
/// the room to the item's right it pushes LEFT until it fits — a panel dragged
/// to 505 points under an item 435 from the screen's edge opened with its
/// right edge at the icon. So the panel is drawn no wider than that room
/// (`shownWidth`, the stored width untouched) and put back under the item on
/// every open (`originX`).
@MainActor
@Observable
final class PanelPlacement {
    static let shared = PanelPlacement()

    /// The room to the item's right, as last measured; nil before the first
    /// open, when nothing caps the width.
    var room: CGFloat?

    /// From the item's left edge to the screen's right edge.
    nonisolated static func room(item: CGRect, visible: CGRect) -> CGFloat {
        visible.maxX - item.minX
    }

    /// Under the item, pulled left only as far as keeps the panel on screen.
    nonisolated static func originX(width: CGFloat, item: CGRect, visible: CGRect) -> CGFloat {
        max(visible.minX, min(item.minX, visible.maxX - width))
    }

    /// The stored width, no wider than the room — and never under the design
    /// width, which the surfaces were never laid out below.
    nonisolated static func shownWidth(stored: CGFloat, room: CGFloat?) -> CGFloat {
        guard let room else { return stored }
        return min(stored, max(room, PanelWidth.designed))
    }

    /// The menu bar item's own window: AppKit's `NSStatusBarWindow`, the
    /// item's rect exactly. The panel's frame cannot stand in for it — by the
    /// time it is read macOS has already shifted it.
    static func itemFrame(among windows: [NSWindow]) -> CGRect? {
        windows.first { String(describing: type(of: $0)) == "NSStatusBarWindow" }?.frame
    }
}
