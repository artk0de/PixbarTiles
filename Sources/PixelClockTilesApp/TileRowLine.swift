import PixelClockKit

/// The one line a tile's row draws: its name, its latest answer, and — when
/// it is not running — a badge saying why.
///
/// Pure values. `drawn` composes what the row shows from what it is given and
/// decides nothing about Focuses or hours: `TileHold` already did that work,
/// and this only names it for the screen.
struct TileRowLine: Equatable {
    enum Badge: Equatable {
        /// Stopped by the user, settings kept.
        case paused
        /// The Mac is in a Focus the tile does not work in.
        case heldByFocus
        /// Inside quiet hours, or outside working ones.
        case silentHours
        /// Its last run did not finish.
        case failing
    }

    let text: String
    let badge: Badge?

    /// The row's text and badge, from the values the model hands over.
    ///
    /// Two spaces between name and result — the row's own spacing. A failing
    /// tile outranks everything: its badge is the answer, and a missing result
    /// is not papered over with filler.
    static func drawn(
        name: String, result: String?, hold: TileHold?, failing: Bool
    ) -> TileRowLine {
        let badge: Badge?
        if failing {
            badge = .failing
        } else {
            switch hold {
            case .paused: badge = .paused
            case .hours: badge = .silentHours
            case .focus: badge = .heldByFocus
            case nil: badge = nil
            }
        }
        return TileRowLine(text: [name, result].compactMap(\.self).joined(separator: "  "),
                           badge: badge)
    }
}
