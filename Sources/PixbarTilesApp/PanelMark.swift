// The panel header's mark: the app icon's P and sparkle without the plate, so
// the header shows the brand the menu bar and the Dock show. Drawn in the
// panel's device palettes (`PanelGlyph.devicePalette`): lit while a clock
// answers, the P greyed and the sparkle out while none does — the state the
// user's clock used to carry in this place.
//
// Deliberately free of AppKit and SwiftUI: a map is data, pinned by golden
// tests; `PixelArt` turns it into pixels.

enum PanelMark {
    /// One point per character. A P cell is 2 x 2 points, keyed by its band
    /// (`b` rows 0-2, `w` rows 3-5, `p` rows 6-8, as the icon colours them);
    /// the sparkle (`*`) keeps the icon's half-cell grid, one point a cell,
    /// one P cell clear of the P and hanging one P cell above it.
    static let map: [String] = {
        let cell = 2
        let sparkleX = PixelP.width * cell + cell
        let pTop = cell
        let width = sparkleX + PixbarIcon.sparkle[0].count
        var rows = Array(repeating: Array(repeating: Character("."), count: width),
                         count: pTop + PixelP.height * cell)
        for (row, line) in PixelP.map.enumerated() {
            let band: Character = row < 3 ? "b" : row < 6 ? "w" : "p"
            for (col, ch) in line.enumerated() where ch == "#" {
                for dy in 0..<cell {
                    for dx in 0..<cell {
                        rows[pTop + row * cell + dy][col * cell + dx] = band
                    }
                }
            }
        }
        for (row, line) in PixbarIcon.sparkle.enumerated() {
            for (col, ch) in line.enumerated() where ch == "#" {
                rows[row][sparkleX + col] = "*"
            }
        }
        return rows.map { String($0) }
    }()
}
