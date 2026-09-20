import PixelClockKit
import SwiftUI

/// What a tile's row shows and does, handed over whole — the model computes
/// nothing here, the view decides nothing. The remove question is part of the
/// value because the row cannot compose it: it does not know which clock it
/// is on, and the question names the clock the tile would be lost from.
struct TileRowValue {
    let name: String
    let result: String?
    /// Why the tile is not running, or nil while it is.
    let hold: TileHold?
    /// Its last run did not finish — outranks everything else on the line.
    let failing: Bool
    /// Runs itself (weather, clock faces) and so draws no run control.
    let isAmbient: Bool
    /// The whole question, clock named: "Remove Weather from Desk?"
    let removeQuestion: String
    let onRun: () -> Void
    let onDetail: () -> Void
    let onRemove: () -> Void

    /// The line the row draws, from the plain type that composes it.
    var line: TileRowLine {
        TileRowLine.drawn(name: name, result: result, hold: hold, failing: failing)
    }
}

/// One tile's row in the panel: the line, the three actions, and the inline
/// removal question.
///
/// Removing loses the tile's settings and, on a TC002, takes its page off the
/// clock — which is why the question is inline and one row tall rather than a
/// system alert: the panel is a small window, and the answer is worth a row.
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
            HStack(spacing: 8) {
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
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(value.name) settings")
                Button { confirming = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(value.name)")
            }
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
