import AppKit
import PixelClockKit
import SwiftUI

/// The tile store: categories on the left, cards on the grid, and each card
/// saying in one glance whether the clock it is aimed at can take it.
///
/// A form with categories, the brief called it — and a form it is: the
/// store is where a tile is CHOSEN, and choosing is reading, which is why
/// this is a window and not a menu. One window, re-aimed by whichever
/// clock's gear opened it; the card grid always answers about that clock.
struct TileStoreWindow: View {
    @Bindable var store: StoreModel
    @Environment(\.openWindow) private var open

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .padding(.top, 24)
            Divider()
            if store.cards.isEmpty {
                // The one window that had no empty state: unaimed — which
                // macOS's own window restoration can produce, since this is a
                // `Window` scene the Window menu can open — it drew a sidebar
                // beside a blank rectangle, and a grid with nothing in it
                // reads as a window that failed to load.
                ContentUnavailableView(
                    "Nothing to add here",
                    systemImage: "square.grid.2x2",
                    description: Text(
                        "Open the store from a clock's gear, or pick another shelf."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12
                    ) {
                        ForEach(store.cards, id: \.candidate) { card in
                            TileStoreCardView(card: card) {
                                store.add(card)
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The refusal, where the press happened. `addTile` has always
            // answered with a reason — a lamp's slot taken, a tile already on
            // the clock — and the store used to drop it, leaving a card that
            // did nothing and said nothing.
            if let refusal = store.lastRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .glassWindow()
        // The two-step commit's second step: a successful add opens the
        // tile's settings window on it, so a tile is never added and
        // forgotten.
        .onChange(of: store.lastAdded) { _, added in
            guard added != nil else { return }
            open(id: "tile-settings")
            NSApp.activate()
        }
    }

    /// The shelves: All first, then every category. One showing at a time;
    /// the grid is the showing one's cards.
    ///
    /// No material of its own. It carried a second `glassEffect` inside a
    /// window that already has one — glass over glass, at a different corner
    /// radius, with a `Divider` drawing the seam a second time beside its
    /// edge. The window's material is the window's; a sidebar that wants to
    /// read as chrome does it by being chrome, not by stacking the same
    /// effect twice.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            shelfButton(nil, title: "All")
            ForEach(TileCategory.allCases, id: \.self) { category in
                shelfButton(category, title: category.title)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 130, alignment: .leading)
    }

    private func shelfButton(_ shelf: TileCategory?, title: String) -> some View {
        let showing = store.category == shelf
        return Button {
            store.category = shelf
        } label: {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(showing ? Color.secondary.opacity(0.2) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        // Which shelf is showing was said in one way only: a slightly
        // different grey behind one of six rows. That is nothing at all to a
        // screen reader, and not much to anybody reading a sidebar at a
        // glance either.
        .accessibilityAddTraits(showing ? [.isSelected] : [])
    }
}

/// One card: a mark, a name, a one-line blurb, and the action the clock's
/// own availability earns — add, Added, or the reason it cannot.
struct TileStoreCardView: View {
    let card: StoreModel.StoreCard
    let onAdd: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var nameInk: UInt32 { PixelInk.primary(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The same badge the clock's own list wears, drawn from the
                // same table: a tile has ONE face, and the store is where
                // somebody meets it first.
                PixelArt(
                    map: PanelGlyph.tile(forConnectorId: card.candidate.connectorId),
                    palette: PanelGlyph.tilePalette(card.candidate.category),
                    pixel: 2
                )
                PixelArt(
                    map: PanelGlyph.text(card.title, in: PixelFont.standard, lit: "G"),
                    palette: PanelGlyph.inkPalette(nameInk),
                    pixel: 2
                )
                .accessibilityLabel(card.title)
                Spacer()
            }
            Text(card.candidate.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var action: some View {
        switch card.action {
        case .add:
            Button(action: onAdd) {
                Text("+ Add").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        case .added:
            Text("Added")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case let .refused(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
