import PixbarKit

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
    /// A failure as the card's line says it — the cause in words, the raw
    /// NSError dictionary kept behind. What the panel's row did, said now by
    /// the grid card that replaced it.
    static func failureWords(_ raw: String) -> String {
        "failing — \(cause(from: raw))"
    }

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

/// The mark each connector's tile wears — on the clock-settings grid's cards
/// and wherever a tile is named beside its face.
///
/// A forwarder now, not a table. It WAS a table, beside the kit's own, and
/// the two had drifted: z.ai was a bar chart on its store card and the
/// "unknown app" mark on its clock card, because this copy had no z.ai case.
/// One tile, two faces, depending on which window was looking. The table
/// lives in `TilePresentation`, where the store already reads it.
/// What a clock's tile card says is wrong: the line under its name, the sign
/// beside it, and the whole text the sign's popover shows.
///
/// A failed push and a GitHub read's diagnosis are two different facts — the
/// clock did not take the page, and the page says the repository is missing
/// — and the card said only the first when both were true. Both are said now,
/// the failure first because it is why the clock may be showing an older page.
struct TileCardTrouble: Equatable {
    enum Sign: Equatable {
        /// The tile does not work — a failed push, a refused token, no repo,
        /// no data: red.
        case blocking
        /// The tile works, a part is withheld from the token: yellow.
        case partial
    }

    let sign: Sign
    let line: String
    /// The popover's text: the raw error behind the words, and the diagnosis.
    let detail: String

    static func of(failure: String?, diagnosis: GitHubDiagnosis?) -> TileCardTrouble? {
        if let failure {
            let words = TileRowLine.failureWords(failure)
            let said = [words, diagnosis?.message].compactMap(\.self)
            let detail = [words, failure, diagnosis?.message].compactMap(\.self)
            return TileCardTrouble(
                sign: .blocking, line: said.joined(separator: "\n"), detail: detail.joined(separator: "\n\n")
            )
        }
        guard let diagnosis else { return nil }
        let sign: Sign = switch diagnosis.severity {
        case .blocking: .blocking
        case .partial: .partial
        }
        return TileCardTrouble(sign: sign, line: diagnosis.message, detail: diagnosis.message)
    }
}

/// A tile's title on a card and on its settings window: the connector's name,
/// and for an instanced tile the instance's (`TilePresentation.secondaryName`).
struct TileTitle: Equatable {
    let name: String
    let secondary: String?

    /// In words — the card draws them in pixels, the window's title says
    /// them: `GitHub - TeaRAGs`, or the name alone for a single tile.
    var text: String {
        secondary.map { "\(name) - \($0)" } ?? name
    }
}

/// The card's bottom-left line: what the tile last did — `delivered`,
/// `running…`, `held` — or nil. A red trouble replaces it: the tile is not
/// working, and its sentence line says why. A yellow one does not — the tile
/// works without a withheld part, so it still says what it last did.
enum TileCardOutcome {
    static func of(trouble: TileCardTrouble?, held: Bool, result: String?) -> String? {
        guard trouble?.sign != .blocking else { return nil }
        return held ? "held" : result
    }
}

enum TileRowIcon {
    static func symbol(forConnectorId connectorId: String) -> String {
        TilePresentation.of(connectorId: connectorId).icon
    }
}
