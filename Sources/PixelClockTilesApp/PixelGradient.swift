import SwiftUI

/// A gradient drawn in BLOCKS rather than as a ramp.
///
/// A SwiftUI `LinearGradient` under a pixel wordmark is the same mismatch an
/// SF Symbol beside a pixel gear was: the app's whole subject is a panel of
/// square lit cells, and a surface that blends smoothly between two colours
/// says it is made of something else.
///
/// What makes it read as pixel art is the QUANTISATION, not the block size. A
/// ramp cut into a handful of steps and laid out on a grid is a gradient
/// somebody could have drawn a cell at a time; the same grid carrying a
/// continuous ramp is just a blurred rectangle with visible seams.
///
/// One tint at falling opacity rather than two colours. The surfaces this sits
/// on are material — light behind it in one appearance and dark in the other —
/// and a pair of opaque colours picked for one of those is wrong in the other.
struct PixelGradient: View {
    /// The colour, as every palette in the app keeps one: 0xRRGGBB.
    let tint: UInt32
    /// Opacity at the top-left corner, where the ramp starts.
    var from: Double = 0.34
    /// Opacity at the bottom-right corner.
    var to: Double = 0.06
    /// The side of one block, in points.
    var pixel: CGFloat = 4
    /// How many opacities the ramp is allowed. Seven is enough to read as a
    /// gradient and few enough that each band is visibly its own colour.
    var steps: Int = 7

    /// The opacity of the block at `position` along the diagonal, quantised.
    ///
    /// `position` runs 0 at the first block to 1 at the last. Separated from
    /// the drawing because this — and nothing about `Canvas` — is what decides
    /// whether the result looks hand-placed.
    static func opacity(
        at position: Double, from: Double, to: Double, steps: Int
    ) -> Double {
        guard steps > 1 else { return from }
        let clamped = min(max(position, 0), 1)
        let band = min(Int(clamped * Double(steps)), steps - 1)
        // The ends are returned rather than computed. `from + (to - from) * 1`
        // is 0.19999999999999996 for a ramp meant to end at 0.2 — invisible on
        // screen and a fact the two corner blocks can be pinned on.
        if band == 0 { return from }
        if band == steps - 1 { return to }
        return from + (to - from) * Double(band) / Double(steps - 1)
    }

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / pixel))
            let rows = Int(ceil(size.height / pixel))
            // Diagonal, so the ramp is visible on a wide short button and on a
            // tall narrow card alike. A horizontal one vanishes on the first.
            let last = Double(max(columns + rows - 2, 1))
            for row in 0..<rows {
                for column in 0..<columns {
                    let opacity = Self.opacity(
                        at: Double(column + row) / last, from: from, to: to, steps: steps
                    )
                    let block = CGRect(
                        x: CGFloat(column) * pixel, y: CGFloat(row) * pixel,
                        width: pixel, height: pixel
                    )
                    context.fill(Path(block), with: .color(Color(hex: tint).opacity(opacity)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
