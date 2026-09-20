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
    /// tile outranks everything: its line is the sentence saying what went
    /// wrong, and a result is not shown beside it.
    static func drawn(
        name: String, result: String?, hold: TileHold?, failure: String?
    ) -> TileRowLine {
        let badge: Badge?
        let text: String
        if let failure {
            badge = .failing
            text = "\(name)  failing — \(cause(from: failure))"
        } else {
            switch hold {
            case .paused: badge = .paused
            case .hours: badge = .silentHours
            case .focus: badge = .heldByFocus
            case nil: badge = nil
            }
            text = [name, result].compactMap(\.self).joined(separator: "  ")
        }
        return TileRowLine(text: text, badge: badge)
    }

    /// What went wrong, in the words a person would say.
    ///
    /// The transports hand back errors in their own dialect — NSError domains
    /// and codes with a quoted diagnostic inside — and that dialect is not a
    /// sentence. Each one the app actually meets is named here once; a failure
    /// with no known dialect keeps its raw message, cut to what a row shows,
    /// rather than being flattened into a word that says nothing.
    static func cause(from raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") { return "timed out" }
        if lower.contains("offline") || lower.contains("not connected to the internet") {
            return "offline"
        }
        if lower.contains("connection was lost") { return "connection lost" }
        if lower.contains("hostname could not be found")
            || lower.contains("cannot find host") { return "server not found" }
        if lower.contains("could not connect to the server")
            || lower.contains("connection refused") {
            return "could not reach the server"
        }
        return String(raw.prefix(60))
    }
}
