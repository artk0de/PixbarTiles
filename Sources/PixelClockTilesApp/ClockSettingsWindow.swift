import Foundation
import PixelClockKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a dragged row lands.
///
/// A function of its own because the two sides speak different languages and
/// the mismatch was silent. SwiftUI's `onMove(from:to:)` hands over an
/// INSERTION index — the slot the row is being dropped BEFORE, measured in the
/// list as it stands with the row still in it. `AppModel.moveTile(_:to:)`
/// takes the row whose PLACE the dragged one should take. Dragging down, the
/// insertion index is one past that row, so feeding it through unchanged put
/// every downward drag one position too far: [weather, claude, anecdotes],
/// drag weather down one, and it landed last.
enum TileReorder {
    /// The index of the row the dragged row should take the place of, or nil
    /// when the drag changes nothing.
    static func landing(draggedFrom source: Int, insertedAt insertion: Int, count: Int) -> Int? {
        guard count > 0, source >= 0, source < count else { return nil }
        let landing = insertion > source ? insertion - 1 : insertion
        guard landing >= 0, landing < count, landing != source else { return nil }
        return landing
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
            // One margin on every side. A leading 48 and a top 20 sat on top
            // of it, which pushed the tabs off-centre and left a band of
            // nothing between the titlebar and the picker.
            .padding(16)
            .frame(minWidth: 440, minHeight: 300)
            .glassWindow()
        } else {
            // A window opened with no aim — its launch state, or the clock
            // it was aimed at having been removed. Says so rather than
            // guessing a clock.
            ContentUnavailableView(
                "No clock selected", systemImage: "clock.badge.questionmark",
                description: Text("Open it from a clock's gear on the panel.")
            )
            .frame(minWidth: 360, minHeight: 220)
            .glassWindow()
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
                        // The open hand is the only thing on this card that
                        // says it can be picked up. `List.onMove` starts the
                        // drag on a press, and a press with no affordance is
                        // a feature nobody finds.
                        //
                        // `pointerStyle` rather than pushing an `NSCursor`,
                        // and that is the whole difference: a pushed cursor
                        // belongs to the ROW, and the gear and the bin are
                        // the row's own children — the pointer never leaves
                        // it, so the hand stayed over controls that are
                        // clicked, not dragged. A pointer style resolves from
                        // the innermost view under the pointer outwards, so
                        // each control's own answer wins over the card's.
                        .pointerStyle(.grabIdle)
                }
                .onMove { from, to in
                    guard let source = from.first,
                        let landing = TileReorder.landing(
                            draggedFrom: source, insertedAt: to, count: records.count
                        )
                    else { return }
                    model.moveTile(records[source].key, to: records[landing].key)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            addCard
        }
    }

    /// The way to a new tile, and the biggest thing on the surface.
    ///
    /// It was a 40pt strip with an SF `plus` and "Add tile" in the system
    /// face, and only the strip answered a press — on a list whose one
    /// remaining action is "add another one". Now it is the width of the
    /// list, tall enough to aim at without looking, set in the clock's own
    /// face, and the whole rectangle is the target: `contentShape` rather
    /// than whatever the label happens to cover.
    ///
    /// A square dashed border rather than a rounded one. The dashes ARE the
    /// pixels — a 2pt stroke broken every 4pt is a row of blocks, which is
    /// the only way a border that has to resize with a window can be drawn in
    /// this vocabulary at all.
    private var addCard: some View {
        Button(action: onAdd) {
            PixelArt(
                map: PanelGlyph.text("ADD TILE", in: PixelFont.standard, lit: "G"),
                palette: PanelGlyph.inkPalette(0xFFFFFF),
                pixel: 3
            )
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                Rectangle().strokeBorder(
                    Color.white, style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
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
    @Environment(\.colorScheme) private var scheme

    @State private var confirming = false

    /// The ink the card's own marks are drawn in — the panel's secondary,
    /// so a gear here and a gear there are the same weight.
    private var chromeInk: UInt32 { PixelInk.secondary(dark: scheme == .dark) }

    private var key: TileKey { record.key }
    private var name: String { model.tileName(of: record) }
    /// The shared table: the shelf the tile is filed on, and its one line.
    private var presentation: TilePresentation {
        TilePresentation.of(connectorId: key.connectorId)
    }

    /// The ink a name is set in — the panel's primary, so a name here and a
    /// name on the panel are the same weight.
    private var nameInk: UInt32 { PixelInk.primary(dark: scheme == .dark) }
    private var accent: Color { Self.accent(for: key.connectorId) }

    /// One colour per SHELF, so a list of cards reads as a set of things with
    /// something in common rather than a wall of the same grey.
    ///
    /// Per shelf and not per connector, which is what it was: two Dev tiles
    /// side by side came out orange and green, and nothing on either card
    /// said what they shared. Through `PanelGlyph.categoryTint`, which is
    /// also what the badge's field is drawn in — one value, so the card and
    /// the mark on it cannot disagree.
    static func accent(for connectorId: String) -> Color {
        Color(hex: PanelGlyph.categoryTint(TilePresentation.of(connectorId: connectorId).category))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The tile's own mark, in the app's pixel vocabulary rather
                // than the system's: this list, the panel and the clock's
                // matrix are one app, and an SF Symbol in `.secondary` beside
                // a pixel gear was two vocabularies on one card.
                PixelArt(
                    map: PanelGlyph.tile(forConnectorId: key.connectorId),
                    palette: PanelGlyph.tilePalette(presentation.category),
                    pixel: 2
                )
                // The name set in the clock's own face, at twice the pixel —
                // which is what makes it read bold beside the line under it.
                PixelArt(
                    map: PanelGlyph.text(name, in: PixelFont.standard, lit: "G"),
                    palette: PanelGlyph.inkPalette(nameInk),
                    pixel: 2
                )
                .accessibilityLabel(name)
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
                    // The panel's own gear, not an SF Symbol: this list and
                    // the panel are the same app, and two vocabularies for
                    // one action is the friction the user reported.
                    PixelArt(map: PanelGlyph.gear, palette: PanelGlyph.inkPalette(chromeInk))
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .accessibilityLabel("\(name) settings")
                .help("\(name) settings")
            }
            // What the tile IS, which the card never said. The name answers
            // "which one", and on a clock carrying two usage tiles that is
            // not the same question.
            if presentation.blurb.isEmpty == false {
                Text(presentation.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = resultLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirming {
                // Said, not just asked twice. The card used to draw a bare
                // Remove beside a bare Cancel with nothing naming what was
                // about to go — the same two buttons on every card of the
                // grid, so the one being answered was whichever one the
                // hand happened to be over.
                InlineConfirmRow(
                    question: "Remove \(name) from this clock?",
                    onConfirm: { model.removeTile(key) },
                    onCancel: { confirming = false }
                )
            } else {
                HStack {
                    Spacer()
                    Button { confirming = true } label: {
                        PixelArt(map: PanelGlyph.bin, palette: PanelGlyph.inkPalette(chromeInk))
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.default)
                    .accessibilityLabel("Remove \(name)")
                    .help("Remove \(name)")
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
        // No `onDrag` here, and its absence is the fix. The card carried one
        // whose payload had NO drop target anywhere in the app — the decoder
        // that read it back had no call site at all — so a drag started, the
        // card lifted, and nothing ever happened. Worse, it competed for the
        // same press-and-drag gesture as the `List.onMove` one row up, which
        // is the reorder that actually works. One mechanism per gesture: the
        // list owns the drag, the platform animates it, and `TileReorder`
        // translates where it landed.
    }

    /// What hovering the card says: a failed tile leads with its error.
    private var cardHelp: String {
        model.lastFailure(of: key).map { TileRowLine.failureWords($0) }
            ?? name
    }

    private var resultLine: String? {
        // `lastFailure(of:)` already falls back to this tile's own
        // maintenance failure. The second lookup that used to sit under it
        // read `lastMaintenanceFailure`, which is projected onto
        // `AppModel.selectedClockId` — so on a card of any clock that is not
        // the selected one it could only ever show ANOTHER clock's failure,
        // and on the selected one it repeated what the line above had said.
        if let failure = model.lastFailure(of: key) {
            return TileRowLine.failureWords(failure)
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

    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if renaming {
                InlineRenameField(
                    current: clock.name,
                    onSave: {
                        settings.renameClock(clock.id, to: $0)
                        renaming = false
                    },
                    onCancel: { renaming = false }
                )
            } else {
                HStack {
                    Text(clock.name).font(.title3)
                    Spacer()
                    Button { renaming = true } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rename \(clock.name)")
                    .help("Rename \(clock.name)")
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
