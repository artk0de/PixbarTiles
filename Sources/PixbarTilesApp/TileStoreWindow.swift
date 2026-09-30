import AppKit
import PixbarKit
import SwiftUI

/// The tile store: shelves on the left, a search and the cards on the right,
/// and each card saying in one glance whether the clock it is aimed at can
/// take it.
///
/// A form with categories, the brief called it — and a form it is: the
/// store is where a tile is CHOSEN, and choosing is reading, which is why
/// this is a window and not a menu. One window, re-aimed by whichever
/// clock's gear opened it; the card grid always answers about that clock.
///
/// Drawn in the hand the clock's own settings window is: shelf rows and
/// cards on block gradients in their shelf's colour, names in the clock's
/// face, the add in the green dashed pixel button.
struct TileStoreWindow: View {
    @Bindable var store: StoreModel
    @Environment(\.openWindow) private var open

    /// Two columns that share the width, with a floor under each wide enough
    /// for the longest name in the clock's face ("Better Weather" at 2pt is
    /// 166pt) beside its badge. The grid that overlapped was `.adaptive(170)`:
    /// a cell narrower than the fixed-width pixel name, so every card's
    /// content spilled into its neighbour's.
    private static let columns = [
        GridItem(.flexible(minimum: 230), spacing: 12, alignment: .top),
        GridItem(.flexible(minimum: 230), spacing: 12, alignment: .top),
    ]

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
                VStack(spacing: 0) {
                    filters
                    Divider()
                    grid
                }
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
        .frame(minWidth: 700, minHeight: 420)
        .glassWindow()
        // A GitHub card asks for its repository before the tile exists.
        .sheet(isPresented: Binding(
            get: { store.askingForRepo != nil },
            set: { if $0 == false { store.cancelRepo() } }
        )) {
            GitHubRepoSheet(
                refusal: store.lastRefusal,
                onAdd: { store.addGitHub(repo: $0) },
                onCancel: { store.cancelRepo() }
            )
        }
        // The two-step commit's second step: a successful add opens the
        // tile's settings window on it, so a tile is never added and
        // forgotten.
        .onChange(of: store.lastAdded) { _, added in
            guard added != nil else { return }
            open(id: "tile-settings")
            WindowFocus.activate()
        }
    }

    /// The search over names and blurbs, and whether the tiles this clock
    /// has no face for are shown at all.
    private var filters: some View {
        HStack(spacing: 12) {
            TextField("Search tiles", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search tiles")
            Toggle("Show unavailable", isOn: $store.showsUnavailable)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Also show the tiles this clock has no face for")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var grid: some View {
        let shown = store.shownCards
        if shown.isEmpty {
            // Filtered to nothing is not the unaimed store: the shelf has
            // cards, the search or the box hid them — say which way out.
            ContentUnavailableView(
                "No tiles match",
                systemImage: "magnifyingglass",
                description: Text(
                    store.showsUnavailable || store.cards.allSatisfy(\.isSupported)
                        ? "Try another word, or another shelf."
                        : "Try another word, or tick Show unavailable."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                    ForEach(shown, id: \.candidate) { card in
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
        VStack(alignment: .leading, spacing: 6) {
            ShelfRow(shelf: nil, title: "All", showing: store.category == nil) {
                store.category = nil
            }
            ForEach(TileCategory.allCases, id: \.self) { category in
                ShelfRow(shelf: category, title: category.title, showing: store.category == category) {
                    store.category = category
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 160, alignment: .leading)
    }
}

/// One shelf in the sidebar: the shelf's own mark and its name in the
/// clock's face, on a block field in the shelf's colour — the colour its
/// cards' badges wear, so a row and what it files cannot disagree.
///
/// The one showing is lit: the field at full strength, the mark and the
/// name knocked out in white, and a solid border in the primary ink. The
/// rest sit faint, their marks in the shelf's colour. Which shelf is showing
/// used to be a slightly different grey behind one of six rows.
private struct ShelfRow: View {
    let shelf: TileCategory?
    let title: String
    let showing: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let tint = PanelGlyph.shelfTint(shelf)
        Button(action: onSelect) {
            HStack(spacing: 6) {
                PixelArt(
                    map: PanelGlyph.shelfMark(shelf),
                    palette: PanelGlyph.inkPalette(showing ? 0xFFFFFF : tint),
                    pixel: 2
                )
                PixelArt(
                    map: PanelGlyph.text(title, in: PixelFont.standard, lit: "G"),
                    palette: PanelGlyph.inkPalette(showing ? 0xFFFFFF : PixelInk.primary(dark: dark)),
                    pixel: 2
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PixelGradient(
                    tint: tint, from: showing ? 0.95 : 0.3, to: showing ? 0.5 : 0.06, pixel: 4
                )
            )
            .overlay(
                Rectangle().strokeBorder(
                    showing ? Color(hex: PixelInk.primary(dark: dark)) : Color(hex: tint).opacity(0.4),
                    lineWidth: 2
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(title)
        // Said to a screen reader too, not only by the lit field.
        .accessibilityAddTraits(showing ? [.isSelected] : [])
    }
}

/// One card: a mark, a name, a one-line blurb, and the action the clock's
/// own availability earns — add, Added, or the reason it cannot. The clock's
/// settings window's card surface, badge and pixel name.
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
                Spacer(minLength: 0)
            }
            Text(card.candidate.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // The action sits on the card's floor, so a row of cards whose
            // blurbs differ in length still lines its buttons up.
            Spacer(minLength: 0)
            action
        }
        .tileCardSurface(card.candidate.category, fillsHeight: true)
    }

    @ViewBuilder
    private var action: some View {
        switch card.action {
        case .add:
            Button(action: onAdd) {
                PixelButtonFace(word: "+ ADD", pixel: 2, minHeight: 30)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel("Add \(card.title)")
        case .added:
            // The Add button's own green, darkened, with a solid border: the
            // state after the act, not another act. Nothing to press, and
            // hovering says why.
            PixelButtonFace(
                word: "ADDED", tint: PanelGlyph.addedTint, ink: 0xDDF5E3,
                border: Color(hex: PanelGlyph.addedTint), dashed: false, pixel: 2, minHeight: 30
            )
            .help(card.hint ?? "")
            .accessibilityElement()
            .accessibilityLabel("\(card.title) added")
            .accessibilityHint(card.hint ?? "")
        case let .refused(reason):
            // The same square field, in grey, with the reason in words that
            // wrap: a pixel sentence cannot, and "not supported on TC-002
            // Pixbar" is wider than the card.
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(PixelGradient(tint: PanelGlyph.allShelvesTint, from: 0.3, to: 0.1, pixel: 4))
                .overlay(
                    Rectangle().strokeBorder(
                        Color(hex: PanelGlyph.allShelvesTint).opacity(0.6), lineWidth: 2
                    )
                )
        }
    }
}
