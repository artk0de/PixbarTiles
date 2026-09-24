import AppKit
import PixbarKit
import SwiftUI

/// The app's name, set the way the app is built.
///
/// Two words and two treatments. `PIXBAR` is drawn in a face the CLOCK itself
/// draws with — not a picture of pixels, the actual bitmap — and `Tiles` is
/// plain regular-weight text. The contrast is SoundSource's, where "Sound" is
/// bold against a plain "Source"; here the loud half is the drawn one, so the
/// name demonstrates what the app does rather than describing it.
///
/// The drawn word comes from `PanelGlyph.text(_:in:)`, so the letters are the
/// kit's table and nothing is redrawn. Change a glyph's bytes and the wordmark
/// changes with the panel the clock shows.
///
/// `Tiles` is not on PIXBAR's baseline, and not on its centre either: its
/// capitals are centred 1.5 clock pixels above PIXBAR's centre, level with the
/// top of PIXBAR's second row. Picked by eye from candidates 0, 0.5, 1 and 1.5
/// pixels up: a bitmap of solid capitals is optically heavier than the text
/// beside it, and a word centred on it exactly reads as hanging low. The lift
/// is in clock pixels, from the font's cap height, so it holds at any `pixel`.
struct Wordmark: View {
    /// How many points one clock pixel is drawn as.
    ///
    /// Two, which puts the five-row face at 10 pt — the cap height of the
    /// `.headline` beside it. A face drawn at its own size next to body text
    /// reads as a footnote that wandered into the title.
    var pixel: CGFloat = 2

    @Environment(\.colorScheme) private var scheme

    /// The face: the kit's 3×5 cell, which is the one with capitals. The
    /// proportional face is prettier and has none, so a wordmark set in it
    /// would have to spell the app's name wrong.
    private static let face = PixelFont.tiny
    static let drawn = "PIXBAR"
    /// The drawn word as a row map.
    static let map = PanelGlyph.text(drawn, in: face)

    /// How far, in clock pixels, the centre of Tiles' capitals sits above the
    /// centre of PIXBAR.
    static let lift: CGFloat = 1.5

    /// Tiles' baseline above PIXBAR's bottom edge, in points: PIXBAR's centre
    /// is half its rows up, the capitals' centre `lift` pixels higher, and the
    /// baseline half a cap height below that.
    static func baselineRise(pixel: CGFloat, capHeight: CGFloat) -> CGFloat {
        (CGFloat(map.count) / 2 + lift) * pixel - capHeight / 2
    }

    /// The cap height of the `.headline` Tiles is set in. Weight moves the
    /// stems, not the cap height, so the regular weight shares it.
    private static var capHeight: CGFloat {
        NSFont.preferredFont(forTextStyle: .headline).capHeight
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            PixelArt(map: Self.map, palette: [PanelGlyph.wordInk: ink], pixel: pixel)
                // The bitmap's "baseline" is placed where Tiles' baseline has
                // to be for its capitals to centre `lift` pixels up.
                .alignmentGuide(.firstTextBaseline) {
                    $0.height - Self.baselineRise(pixel: pixel, capHeight: Self.capHeight)
                }
            Text("Tiles").font(.headline.weight(.regular))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PixbarTiles")
    }

    private var ink: UInt32 {
        PixelInk.primary(dark: scheme == .dark)
    }
}
