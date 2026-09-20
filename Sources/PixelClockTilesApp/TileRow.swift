import PixelClockKit
import SwiftUI

/// What a tile's row shows and does, handed over whole — the model computes
/// nothing here, the view decides nothing. The remove question is part of the
/// value because the row cannot compose it: it does not know which clock it
/// is on, and the question names the clock the tile would be lost from. The
/// key is part of the value because the row's identity in the panel IS the
/// tile's: rows are told apart by it, so a reordered list moves the right
/// row instead of redrawing every row as somebody else.
struct TileRowValue {
    let key: TileKey
    let name: String
    let result: String?
    /// Why the tile is not running, or nil while it is.
    let hold: TileHold?
    /// What its last run or restock complained about, in the raw words the
    /// transport produced — or nil while nothing did. The line turns it into
    /// a sentence; the raw text stays behind here, off the row.
    let failure: String?
    /// Runs itself (weather, clock faces) and so draws no run control.
    let isAmbient: Bool
    /// The connector's mark, as the row draws it ahead of the name.
    let iconName: String
    /// The whole question, clock named: "Remove Weather from Desk?"
    let removeQuestion: String
    let onRun: () -> Void
    let onDetail: () -> Void
    let onRemove: () -> Void
    /// The row a dropped drag came from, handed to the model with this row
    /// as where it landed. Called only when a drag actually ends here.
    let onReorderTo: (TileKey) -> Void

    /// The line the row draws, from the plain type that composes it.
    var line: TileRowLine {
        TileRowLine.drawn(name: name, result: result, hold: hold, failure: failure)
    }
}

/// The mark each connector's row opens with.
///
/// A table rather than a `Connector` member so the kit stays out of naming
/// screen marks: the panel reads its own dialect of SF Symbols, and a
/// connector with no row here is drawn the "unknown app" mark rather than
/// nothing.
enum TileRowIcon {
    static func symbol(forConnectorId connectorId: String) -> String {
        switch connectorId {
        // The ids as the connectors spell them — `id` is an instance member
        // on the scene connectors, and spelling it here is cheaper than
        // building one to read it.
        case "weather": return "cloud.sun"
        case "claude": return "terminal"
        case "anecdotes": return "text.bubble"
        case VPNConnector.id: return "lock.shield"
        default: return "app.dashed"
        }
    }
}

/// One tile's row in the panel: the line, the three actions, and the inline
/// removal question.
///
/// Removing loses the tile's settings and, on a TC002, takes its page off the
/// clock — which is why the question is inline and one row tall rather than a
/// system alert: the panel is a small window, and the answer is worth a row.
/// The row is also the unit of order: it drags, and a drag landing on it
/// names the row that landed as the one to move.
struct TileRow: View {
    let value: TileRowValue
    @State private var confirming: Bool

    init(value: TileRowValue) {
        self.value = value
        _confirming = State(initialValue: false)
    }

    /// The confirmation state, entered directly — how the tests reach the
    /// question without driving the button, and how the row looks while it is
    /// being answered.
    init(value: TileRowValue, confirming: Bool) {
        self.value = value
        _confirming = State(initialValue: confirming)
    }

    var body: some View {
        if confirming {
            HStack(spacing: 8) {
                Text(value.removeQuestion)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Remove") { value.onRemove() }
                    .controlSize(.small)
                Button("Cancel") { confirming = false }
                    .controlSize(.small)
            }
        } else {
            row
                // The drag carries the tile's key as text, and the drop lands
                // on whichever row it was released over: the panel is a short
                // list, and row-for-row is as fine as a reorder of it needs
                // to be.
                .draggable(value.key.dragPayload)
                .dropDestination(for: String.self) { payload, _ in
                    guard let source = payload.first,
                        let key = TileKey(dragPayload: source)
                    else { return false }
                    value.onReorderTo(key)
                    return true
                }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: value.iconName)
                .foregroundStyle(.secondary)
                .accessibilityLabel(value.name)
            if !value.isAmbient {
                Button { value.onRun() } label: {
                    Text("▶")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Run \(value.name)")
            }
            Text(value.line.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let badge = value.line.badge {
                Text(Self.glyph(for: badge))
                    .font(.caption)
                    .accessibilityLabel(Self.badgeName(for: badge))
            }
            Spacer()
            Button { value.onDetail() } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(value.name) settings")
            Button { confirming = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(value.name)")
        }
    }

    /// The badge as the mark the row draws beside the line. The names differ
    /// from the hold's own because the mark speaks to a glance, not to code.
    private static func glyph(for badge: TileRowLine.Badge) -> String {
        switch badge {
        case .paused: "⏸"
        case .heldByFocus: "🎯"
        case .silentHours: "🌙"
        case .failing: "⚠️"
        }
    }

    private static func badgeName(for badge: TileRowLine.Badge) -> String {
        switch badge {
        case .paused: "Paused"
        case .heldByFocus: "Held by a Focus"
        case .silentHours: "Silent hours"
        case .failing: "Failing"
        }
    }
}

/// A tile's key, as a drag carries it.
///
/// One line of text with the three parts of the key in it, because a drag
/// payload wants a self-contained value and the key already is one — the
/// round trip is what `TileKey(dragPayload:)` is for, and nothing else reads
/// the format.
extension TileKey {
    var dragPayload: String {
        [clockId.uuidString, connectorId, instance].joined(separator: "|")
    }

    init?(dragPayload payload: String) {
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let clockId = UUID(uuidString: String(parts[0])) else {
            return nil
        }
        self.init(clockId: clockId, connectorId: String(parts[1]), instance: String(parts[2]))
    }
}
