import SwiftUI

/// Draws a character map in a palette, `pixel` points per art pixel — the
/// panel's side of what `Scripts/MakeIcon.swift` does for the menu bar.
///
/// A `Canvas` of filled squares rather than an image resampled to size, so the
/// edges stay hard at any whole-device-pixel scale: 2 is two device pixels at
/// @1x and four at @2x, 1.5 is three at @2x.
struct PixelArt: View {
    let map: [String]
    let palette: PanelGlyph.Palette
    var pixel: CGFloat = 2

    var body: some View {
        let rows = map.map(Array.init)
        let width = rows.first?.count ?? 0
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, key) in row.enumerated() {
                    guard let hex = palette[key] ?? nil else { continue }
                    let square = CGRect(
                        x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel
                    )
                    context.fill(Path(square), with: .color(Color(hex: hex)))
                }
            }
        }
        .frame(width: CGFloat(width) * pixel, height: CGFloat(rows.count) * pixel)
        // Decoration: the words beside every mark carry what it means.
        .accessibilityHidden(true)
    }
}

extension Color {
    /// A 0xRRGGBB value in sRGB — the form every palette in the app keeps.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The ink the one-colour marks and the battery housing are drawn in: the
/// user's clock's own frame colour in each appearance, so the marks and the
/// clock beside them are one hand.
enum PixelInk {
    static func primary(dark: Bool) -> UInt32 { dark ? 0xD0D2DC : 0x1D1D1F }
    static func secondary(dark: Bool) -> UInt32 { dark ? 0x8E909A : 0x6E6E73 }
}
