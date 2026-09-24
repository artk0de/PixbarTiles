import PixbarKit
import SwiftUI

/// The app's name, set the way the app is built.
///
/// Three words and three treatments, and the middle one is the point: **Pixel**
/// carries the weight, `Clock` is drawn in a face the CLOCK itself draws with —
/// not a picture of pixels, the actual bitmap — and `Tiles` drops back to the
/// regular weight. The contrast is SoundSource's, where "Sound" is bold against
/// a plain "Source"; what it buys here is that the name demonstrates its own
/// three parts rather than describing them.
///
/// The drawn middle comes from `PanelGlyph.text(_:in:)`, so the letters are the
/// kit's table and nothing is redrawn. Change a glyph's bytes and the wordmark
/// changes with the panel the clock shows.
struct Wordmark: View {
    /// How many points one clock pixel is drawn as.
    ///
    /// Two, which puts the five-row face at 10 pt — the cap height of the
    /// `.headline` beside it. A face drawn at its own size next to body text
    /// reads as a footnote that wandered into the title.
    var pixel: CGFloat = 2

    @Environment(\.colorScheme) private var scheme

    /// The face: the kit's 3×5 cell, which is the one that carries a capital C.
    /// The proportional face is prettier and has no capitals at all, so a
    /// wordmark set in it would have to spell the app's name wrong.
    private static let face = PixelFont.tiny
    private static let drawn = "Clock"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Pixel").font(.headline)
            PixelArt(
                map: PanelGlyph.text(Self.drawn, in: Self.face),
                palette: [PanelGlyph.wordInk: ink],
                pixel: pixel
            )
            // Aligned on the baseline rather than centred: the drawn word has
            // no descenders, so its last row IS its baseline, and a centred
            // bitmap floats above the words either side of it.
            .alignmentGuide(.firstTextBaseline) { $0.height }
            Text("Tiles").font(.headline.weight(.regular))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PixelClockTiles")
    }

    private var ink: UInt32 {
        PixelInk.primary(dark: scheme == .dark)
    }
}
