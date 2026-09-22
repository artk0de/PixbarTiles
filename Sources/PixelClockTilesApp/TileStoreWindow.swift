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
        }
        .frame(minWidth: 560, minHeight: 380)
        .glassWindow(cornerRadius: 16)
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
    /// the grid is the showing one's cards. Liquid Glass lives HERE rather
    /// than on the grid, because the spec draws the material's line where
    /// macOS 26 does: navigation chrome takes it, content stays opaque.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            shelfButton(nil, title: "All")
            Divider().padding(.vertical, 4)
            ForEach(TileCategory.allCases, id: \.self) { category in
                shelfButton(category, title: category.title)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 130, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func shelfButton(_ shelf: TileCategory?, title: String) -> some View {
        Button {
            store.category = shelf
        } label: {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(
                    store.category == shelf
                        ? Color.secondary.opacity(0.2) : Color.clear
                )
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

/// One card: a mark, a name, a one-line blurb, and the action the clock's
/// own availability earns — add, Added, or the reason it cannot.
struct TileStoreCardView: View {
    let card: StoreModel.StoreCard
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: card.candidate.storeIcon)
                    .font(.system(size: 22))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
                Text(card.title).font(.headline)
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
