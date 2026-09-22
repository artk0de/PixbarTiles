import Foundation
import PixelClockKit
import SwiftUI
import UniformTypeIdentifiers

/// The tile drag's payload: the key said in one string, read back by the
/// card it is dropped on. `|` separates the three parts, and an empty
/// instance collapses — the round trip is the contract its test pins.
extension TileKey {
    var dragPayload: String {
        [clockId.uuidString, connectorId, instance].joined(separator: "|")
    }

    init?(dragPayload: String) {
        let parts = dragPayload.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let clockId = UUID(uuidString: String(parts[0])) else {
            return nil
        }
        self.init(clockId: clockId, connectorId: String(parts[1]), instance: String(parts[2]))
    }
}

/// One clock's own settings window, aimed by its gear: the Tiles tab where
/// the clock's tiles are managed as the cards they are, and the General tab
/// where the clock itself is named.
///
/// One window, re-aimed by whichever gear asked — the content reads the
/// facade's aim, so a second gear's click moves it rather than stacking a
/// second one. The tiles are a GRID, not a list, because a tile is a thing
/// the clock shows, and the grid is how a set of things reads; the list
/// vocabulary belongs to rows of settings, which this is not.
struct ClockSettingsWindow: View {
    @Bindable var settings: SettingsModel
    @ObservedObject var model: AppModel
    let store: StoreModel
    @Environment(\.openWindow) private var open

    var body: some View {
        if let clock = settings.aimedClock {
            VStack(spacing: 0) {
                Picker("Tab", selection: $settings.clockTab) {
                    ForEach(SettingsModel.ClockTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                Divider()
                switch settings.clockTab {
                case .tiles:
                    TilesGrid(
                        clock: clock, model: model, settings: settings,
                        onAdd: { openGridTarget(clock.id) }
                    )
                case .general:
                    ClockGeneralTab(clock: clock, model: model, settings: settings)
                }
            }
            .padding(16)
            .padding(.top, 20)
            .padding(.leading, 48)
            .frame(minWidth: 440, minHeight: 300)
            .glassWindow(cornerRadius: 16)
        } else {
            // A window opened with no aim — its launch state, or the clock
            // it was aimed at having been removed. Says so rather than
            // guessing a clock.
            ContentUnavailableView(
                "No clock selected", systemImage: "clock.badge.questionmark",
                description: Text("Open it from a clock's gear on the panel.")
            )
            .frame(minWidth: 360, minHeight: 220)
            .glassWindow(cornerRadius: 16)
        }
    }

    /// The clock is passed in rather than read back off the facade: the aim
    /// lives inside `body`'s `if let`, and a method reaching for a `clock`
    /// that is not in its scope resolves to Darwin's `clock()` instead of
    /// failing to compile — which is exactly what it did.
    private func openGridTarget(_ clockId: UUID) {
        // The store answers about the clock it is aimed at: aiming FIRST is
        // what makes its cards exist. An unaimed store is an empty grid —
        // the defect this ordering closes.
        store.show(clockId)
        open(id: "tile-store")
        NSApp.activate()
    }
}

// MARK: - The tiles tab

/// The clock's tiles as cards on a grid: what each one is, what it last did,
/// and the three moves — settings, move, remove. The add is a card of its
/// own at the end, because that is where a set grows.
private struct TilesGrid: View {
    let clock: ClockRecord
    @ObservedObject var model: AppModel
    let settings: SettingsModel
    let onAdd: () -> Void
    @Environment(\.openWindow) private var open

    private var records: [TileRecord] {
        model.tileRecords.filter { $0.key.clockId == clock.id }
    }

    var body: some View {
        VStack(spacing: 10) {
            // A List because reorder-by-drag is what List.onMove owns: the
            // platform starts the drag, animates the move, and hands the
            // offsets back — every gesture reimplementation before it lost
            // to the buttons living on the card. The rows draw the cards;
            // the chrome is stripped.
            List {
                ForEach(records, id: \.key) { record in
                    ClockTileCard(record: record, model: model)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    guard let source = from.first else { return }
                    let destination = min(max(to, 0), records.count - 1)
                    guard destination != source else { return }
                    model.moveTile(records[source].key, to: records[destination].key)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            addCard
        }
    }

    /// Compact, one row tall: the grid grows by one of its own.
    private var addCard: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Add tile").font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tile to \(clock.name)")
    }

}

/// One tile of the clock, as a card in the connector's own colour: its mark
/// and name, its last result, and the gear that opens its settings. The
/// whole card is the drag; dropping it on another card is the move.
private struct ClockTileCard: View {
    let record: TileRecord
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var open

    @State private var confirming = false

    private var key: TileKey { record.key }
    private var name: String { model.tileName(of: record) }
    private var accent: Color { Self.accent(for: key.connectorId) }

    /// One colour per connector, so a grid of cards reads as a set of
    /// different things rather than a wall of the same grey. The map is the
    /// panel's own SF Symbol table's sibling — same keys, one hue each.
    static func accent(for connectorId: String) -> Color {
        switch connectorId {
        case "weather": .cyan
        case "claude": .orange
        case "zai": .green
        case "anecdotes": .pink
        case VPNConnector.id: .purple
        default: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: TileRowIcon.symbol(forConnectorId: key.connectorId))
                    .foregroundStyle(accent)
                Text(name).font(.callout).lineLimit(1)
                Spacer()
                if let failure = model.lastFailure(of: key) {
                    // A failed push is THIS tile's error, said where the tile
                    // lives: the red sign, the words on hover.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(failure)
                }
                Button {
                    model.openDetail(for: key)
                    open(id: "tile-settings")
                    NSApp.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(name) settings")
            }
            if let line = resultLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if confirming {
                    Button("Remove") { model.removeTile(key) }
                        .controlSize(.small)
                    Button("Cancel") { confirming = false }
                        .controlSize(.small)
                } else {
                    Button { confirming = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(name)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.14)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(cardHelp)
        // The whole card is the drag — through `onDrag`, whose item provider
        // starts reliably inside a scrolling grid of buttons, where
        // `.draggable` loses the gesture to the button hit-testing. A plain
        // click is the settings' door.
        .onDrag {
            NSItemProvider(object: key.dragPayload as NSString)
        }
    }

    /// What hovering the card says: a failed tile leads with its error.
    private var cardHelp: String {
        model.lastFailure(of: key).map { TileRowLine.failureWords($0) }
            ?? name
    }

    private var resultLine: String? {
        if let failure = model.lastFailure(of: key) {
            return TileRowLine.failureWords(failure)
        }
        if let restock = model.lastMaintenanceFailure[key.connectorId] {
            return TileRowLine.failureWords(restock)
        }
        if model.hold(of: key) != nil { return "held" }
        return model.lastResult(of: key)
    }
}

// MARK: - The general tab

/// The clock itself: its name, and the facts that name sits on.
private struct ClockGeneralTab: View {
    let clock: ClockRecord
    @ObservedObject var model: AppModel
    let settings: SettingsModel

    @State private var name = ""
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if renaming {
                TextField(clock.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        settings.renameClock(clock.id, to: name)
                        renaming = false
                    }
                    .controlSize(.small)
                    Button("Cancel") { renaming = false }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text(clock.name).font(.title3)
                    Spacer()
                    Button {
                        name = clock.name
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rename \(clock.name)")
                }
            }
            Text("\(clock.model.spokenName) · \(clock.address)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.statusLine(of: clock))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let battery = model.batteryLine(of: clock) {
                Text(battery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
