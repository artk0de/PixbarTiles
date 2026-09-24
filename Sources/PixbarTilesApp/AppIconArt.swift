// The PixbarTiles app icon: the pixel P and a sparkle lit on a 17 x 17 LED
// grid, on a near-black plate. Approved in the browser on 2026-09-24
// (`docs/superpowers/specs/2026-09-24-pixbar-brand-design.md`, oracle
// `pixbar-brand/app-icon.html`). Compiled into the app so the tests can pin it
// and into `Scripts/MakeIcon.swift`, which draws these marks with
// CoreGraphics — the icon is round dots and a rounded plate, so unlike the
// menu bar glyph its antialiasing is CG's, and its geometry is what is shared.
//
// Deliberately free of AppKit: the layout and the marks are pure functions of
// the canvas size.

enum PixbarIcon {
    static let plate: UInt32 = 0x141417
    static let blue: UInt32 = 0x4FB8F5
    static let white: UInt32 = 0xEEF0F4
    static let purple: UInt32 = 0xB65CF5
    static let cyan: UInt32 = 0x63D1FF
    /// An unlit dot: white at 6 %.
    static let unlitAlpha = 0.06

    /// The LED grid is 17 x 17 cells.
    static let grid = 17

    /// The sparkle: an open plus on a 7 x 7 half-cell grid — the plus of arm
    /// width 3 reduced to its outline (a cell with a 4-neighbour outside it),
    /// the four arm tips removed so the arms stay open.
    static let sparkle: [String] = {
        let n = 7, a0 = 2, a1 = 4, mid = 3
        let solid = { (x: Int, y: Int) in
            x >= 0 && y >= 0 && x < n && y < n && ((x >= a0 && x <= a1) || (y >= a0 && y <= a1))
        }
        return (0..<n).map { y in
            String((0..<n).map { x -> Character in
                let edge = solid(x, y)
                    && (!solid(x - 1, y) || !solid(x + 1, y) || !solid(x, y - 1) || !solid(x, y + 1))
                let tip = ((y == 0 || y == n - 1) && x == mid) || ((x == 0 || x == n - 1) && y == mid)
                return edge && !tip ? "#" : "."
            })
        }
    }()
    /// Each sparkle cell is a square of this many half-cells — the "bold"
    /// weight — centred in its half-cell.
    static let sparkleWeight = 1.35

    /// The P and the sparkle side by side, in grid cells: the P's 7, a gap of
    /// one, the sparkle's 3.5 rounded up to 4; the P's 9 rows and two more.
    static let pairWidth = PixelP.width + 1 + 4
    static let pairHeight = PixelP.height + 2
    /// Centred, then shifted one cell right: the pair's left edge.
    static let gx0 = (grid - pairWidth) / 2 + 1
    /// Centred: the pair's top edge. The sparkle hangs from it; the P starts
    /// a row below — lifted one from the two rows the pair allows it.
    static let gy0 = (grid - pairHeight) / 2

    /// The canvas arithmetic, in pixels of a `size`-pixel square.
    struct Layout: Equatable {
        /// The plate's inset on every side.
        let inset: Int
        let cornerRadius: Double
        /// One grid cell.
        let cell: Int
        /// The grid's top-left, both axes: the grid is centred.
        let origin: Int
    }

    static func layout(size: Int) -> Layout {
        let s = Double(size)
        let cell = Int((s * 0.84 / Double(grid)).rounded(.down))
        return Layout(
            inset: Int((s * 0.08).rounded()),
            cornerRadius: s * 0.225,
            cell: cell,
            origin: Int((Double(size - grid * cell) / 2).rounded())
        )
    }

    /// A P row's colour: three bands of three rows, blue, white, purple.
    static func colour(ofPRow row: Int) -> UInt32 {
        row < 3 ? blue : row < 6 ? white : purple
    }

    /// The P's colour at a grid cell, or nil for an unlit dot.
    static func litColour(col: Int, row: Int) -> UInt32? {
        let x = col - gx0, y = row - (gy0 + 1)
        return PixelP.isLit(col: x, row: y) ? colour(ofPRow: y) : nil
    }

    enum Shape: Equatable {
        case roundedRect(PixbarGlyph.Rect, radius: Double)
        case circle(x: Double, y: Double, radius: Double)
        case rect(PixbarGlyph.Rect)

        /// Whether a point, in pixels with y down, is inside the shape.
        func contains(x px: Double, y py: Double) -> Bool {
            switch self {
            case let .rect(r):
                return px >= r.x && px < r.x + r.width && py >= r.y && py < r.y + r.height
            case let .circle(cx, cy, radius):
                return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= radius * radius
            case let .roundedRect(r, radius):
                guard px >= r.x, px <= r.x + r.width, py >= r.y, py <= r.y + r.height else { return false }
                let nx = min(max(px, r.x + radius), r.x + r.width - radius)
                let ny = min(max(py, r.y + radius), r.y + r.height - radius)
                return (px - nx) * (px - nx) + (py - ny) * (py - ny) <= radius * radius
            }
        }
    }

    /// One mark of the drawing, applied in order over what came before.
    struct Mark: Equatable {
        let shape: Shape
        let rgb: UInt32
        let alpha: Double
    }

    /// The icon as the ordered marks that draw it — the oracle's own order:
    /// the plate, every dot of the grid (lit or unlit), the sparkle over them.
    static func marks(size: Int) -> [Mark] {
        let layout = layout(size: size)
        let cell = Double(layout.cell), origin = Double(layout.origin)
        let inset = Double(layout.inset), s = Double(size)
        var marks = [Mark(
            shape: .roundedRect(
                PixbarGlyph.Rect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                radius: layout.cornerRadius
            ),
            rgb: plate, alpha: 1
        )]
        for row in 0..<grid {
            for col in 0..<grid {
                let dot = Shape.circle(x: origin + Double(col) * cell + cell / 2,
                                       y: origin + Double(row) * cell + cell / 2,
                                       radius: cell * 0.42)
                if let lit = litColour(col: col, row: row) {
                    marks.append(Mark(shape: dot, rgb: lit, alpha: 1))
                } else {
                    marks.append(Mark(shape: dot, rgb: 0xFFFFFF, alpha: unlitAlpha))
                }
            }
        }
        // Each sparkle square pixel-rounded, as the oracle's `fillRect` of
        // rounded numbers: a crisp square at every size the master is drawn at.
        let half = cell / 2, side = half * sparkleWeight
        let sx = origin + Double(gx0 + PixelP.width + 1) * cell, sy = origin + Double(gy0) * cell
        for (y, line) in sparkle.enumerated() {
            for (x, character) in line.enumerated() where character == "#" {
                let cx = sx + Double(x) * half + half / 2, cy = sy + Double(y) * half + half / 2
                marks.append(Mark(
                    shape: .rect(PixbarGlyph.Rect(
                        x: (cx - side / 2).rounded(), y: (cy - side / 2).rounded(),
                        width: side.rounded(), height: side.rounded()
                    )),
                    rgb: cyan, alpha: 1
                ))
            }
        }
        return marks
    }

    /// The icon at one pixel, sampled at its centre with no antialiasing: the
    /// marks composited in order. What the tests pin; the generator draws the
    /// same marks antialiased.
    static func sample(size: Int, x: Int, y: Int) -> PixbarGlyph.Pixel {
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for mark in marks(size: size) where mark.shape.contains(x: px, y: py) {
            let c = mark.alpha
            r = PixbarGlyph.channel(mark.rgb, 16) * c + r * (1 - c)
            g = PixbarGlyph.channel(mark.rgb, 8) * c + g * (1 - c)
            b = PixbarGlyph.channel(mark.rgb, 0) * c + b * (1 - c)
            a = c + a * (1 - c)
        }
        return PixbarGlyph.straight(r: r, g: g, b: b, a: a)
    }
}
