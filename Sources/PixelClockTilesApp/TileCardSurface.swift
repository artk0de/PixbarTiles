import PixelClockKit
import SwiftUI

// The pieces a tile card is drawn from, shared by the two windows that draw
// tile cards — the clock's own settings and the tile store. One tile wears
// one card: a store card that looked like a different app's was the friction
// the redesign was asked for.

/// A tile card's ground: its shelf's colour as a block gradient, a rounded
/// edge in the same colour, and the whole card as the hit shape.
struct TileCardSurface: ViewModifier {
    let category: TileCategory
    /// Whether the card stretches to the height it is offered — a grid cell
    /// in a row of taller cards — rather than hugging its content.
    var fillsHeight = false

    func body(content: Content) -> some View {
        let tint = PanelGlyph.categoryTint(category)
        content
            .padding(10)
            .frame(
                maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil,
                alignment: .topLeading
            )
            .background(
                PixelGradient(tint: tint)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(hex: tint).opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    /// Draws this as a tile card of `category`'s shelf.
    func tileCardSurface(_ category: TileCategory, fillsHeight: Bool = false) -> some View {
        modifier(TileCardSurface(category: category, fillsHeight: fillsHeight))
    }
}

/// A pixel button face: a word set in the clock's own face on a block
/// gradient, inside a square border.
///
/// The ADD face — green, dashed — is the one act on its surface. A DASHED
/// square border rather than a rounded one: a 2pt stroke broken every 4pt
/// is a row of blocks, which is the only way a border that resizes with its
/// window can be drawn in this vocabulary. A state that is not an act (the
/// store's Added) wears a solid border, so it does not read as a button.
struct PixelButtonFace: View {
    let word: String
    var tint: UInt32 = PanelGlyph.addTint
    var ink: UInt32 = 0xFFFFFF
    var border: Color = .white
    var dashed = true
    var pixel: CGFloat = 3
    var minHeight: CGFloat = 64

    var body: some View {
        PixelArt(
            map: PanelGlyph.text(word, in: PixelFont.standard, lit: "G"),
            palette: PanelGlyph.inkPalette(ink),
            pixel: pixel
        )
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(PixelGradient(tint: tint, from: 0.95, to: 0.4, pixel: 4))
        .background(
            Rectangle().strokeBorder(
                border, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 4] : [])
            )
        )
        .contentShape(Rectangle())
    }
}
