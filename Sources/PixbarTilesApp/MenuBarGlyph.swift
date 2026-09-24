// The PixbarTiles menu bar glyph: a pixel P on a screen, approved in the
// browser on 2026-09-24 (`docs/superpowers/specs/2026-09-24-pixbar-brand-
// design.md`, oracle `pixbar-brand/menu-bar-glyph.html`). This file is the
// glyph's single home — `Scripts/MakeIcon.swift` is compiled alongside it and
// ships what it rasterizes, so the art on the bar and the art the generator
// writes cannot drift apart.
//
// Deliberately free of AppKit: the geometry is data and the raster is a pure
// function of it, and those are what the golden tests pin. Turning a raster
// into CG pixels lives in the generator.

/// The pixel P both marks are drawn around: 7 columns x 9 rows, a three-column
/// stem, a six-row bowl with a 2 x 2 counter, the bowl's two right corners
/// cut. The app icon lights it on an LED grid (`PixbarIcon`); the menu bar
/// knocks it out of the screen or traces its contour (`PixbarGlyph`).
enum PixelP {
    static let map = [
        "######.",
        "#######",
        "###..##",
        "###..##",
        "#######",
        "######.",
        "###....",
        "###....",
        "###....",
    ]
    static let width = 7
    static let height = 9

    static func isLit(col: Int, row: Int) -> Bool {
        row >= 0 && row < height && col >= 0 && col < width
            && Array(map[row])[col] == "#"
    }
}

enum PixbarGlyph {
    /// Which of the three drawings the bar is showing — the same three
    /// `AppGlyph.State` tells apart, spelled here so the generator, which is
    /// compiled without the app, can name them.
    enum State: CaseIterable {
        /// A clock answers: the case filled, the P and a bezel knocked out.
        case online
        /// Clocks are configured and none answers: the case stroked, the P as
        /// a contour, a red square on the corner.
        case offline
        /// No clock is configured: the case stroked and nothing on its screen.
        case empty
    }

    /// Which bar the glyph is drawn for. The offline red cannot come from a
    /// template image, so the glyph is drawn per appearance rather than
    /// tinted by AppKit.
    enum Appearance: CaseIterable {
        case dark
        case light

        /// White on a dark bar, black on a light one, 0xRRGGBB.
        var ink: UInt32 { self == .dark ? 0xFFFFFF : 0x000000 }
    }

    /// The offline square's red.
    static let red: UInt32 = 0xD6001C

    /// The canvas, in points: 28 x 18 at every scale — the bar caps an item's
    /// height at 18 pt, and the case with its feet is exactly that tall.
    static let width = 28
    static let height = 18

    // MARK: Geometry, in points

    /// An axis-aligned rectangle in points, y down.
    struct Rect: Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        func offsetBy(dx: Double, dy: Double) -> Rect {
            Rect(x: x + dx, y: y + dy, width: width, height: height)
        }

        /// The area this rectangle shares with another.
        func overlap(_ other: Rect) -> Double {
            let w = min(x + width, other.x + other.width) - max(x, other.x)
            let h = min(y + height, other.y + other.height) - max(y, other.y)
            return w > 0 && h > 0 ? w * h : 0
        }
    }

    /// A shape as disjoint rectangles, less disjoint holes that lie inside
    /// them. Everything the glyph draws is rectilinear — the staircase
    /// corners are what make that true — so this is the whole vocabulary,
    /// and its coverage of a device pixel is exact area, not a sample.
    struct Region {
        var rects: [Rect]
        var holes: [Rect] = []

        func offsetBy(dx: Double, dy: Double) -> Region {
            Region(rects: rects.map { $0.offsetBy(dx: dx, dy: dy) },
                   holes: holes.map { $0.offsetBy(dx: dx, dy: dy) })
        }

        /// How much of `pixel` the region covers, 0...1.
        func coverage(of pixel: Rect) -> Double {
            let area = rects.reduce(0) { $0 + $1.overlap(pixel) }
                - holes.reduce(0) { $0 + $1.overlap(pixel) }
            return min(1, max(0, area / (pixel.width * pixel.height)))
        }
    }

    /// A rectangle with its four corners cut as a staircase of `steps` 1-pt
    /// steps, as horizontal bands: each of the top and bottom `steps` rows is
    /// inset one point less than the row outside it, the rows between run the
    /// full width.
    static func stepped(x0: Double, y0: Double, x1: Double, y1: Double, steps: Int) -> Region {
        var bands: [Rect] = []
        for i in 0..<steps {
            let inset = Double(steps - i)
            bands.append(Rect(x: x0 + inset, y: y0 + Double(i), width: x1 - x0 - 2 * inset, height: 1))
            bands.append(Rect(x: x0 + inset, y: y1 - Double(i) - 1, width: x1 - x0 - 2 * inset, height: 1))
        }
        let s = Double(steps)
        bands.append(Rect(x: x0, y: y0 + s, width: x1 - x0, height: y1 - y0 - 2 * s))
        return Region(rects: bands)
    }

    // The case: 26 x 15 pt, its outline a 2-step staircase at every corner,
    // stroked 1.5 pt on the path inset by 0.75 pt with miter joins. For a
    // rectilinear path a mitered stroke is exactly the path pushed out by half
    // the width less the path pulled in by it, and both are staircases of
    // 1-pt steps again: the outside at 0...26 x 0...15, the inside at
    // 1.5...24.5 x 1.5...13.5. Coordinates here are the spec's, before the
    // canvas shift of (1, 0.5) pt.
    static let caseWidth = 26.0
    static let caseHeight = 15.0
    static let stroke = 1.5
    static let stairs = 2

    /// What the online state FILLS: the case out to the outline the stroked
    /// states draw. The oracle filled the stroke's centreline, 0.75 pt
    /// inside it, and the glyph shrank by half a stroke every time a clock
    /// came back.
    static let caseFill = stepped(x0: 0, y0: 0, x1: caseWidth, y1: caseHeight, steps: stairs)

    /// The case's 1.5-pt stroke, outside less inside.
    static let caseStroke: Region = {
        let outside = stepped(x0: 0, y0: 0, x1: caseWidth, y1: caseHeight, steps: stairs)
        let inside = stepped(x0: stroke, y0: stroke, x1: caseWidth - stroke,
                             y1: caseHeight - stroke, steps: stairs)
        return Region(rects: outside.rects, holes: inside.rects)
    }()

    /// Two 2.5 x 1.5 pt feet, square-cornered, their top edge at y = 14.5 —
    /// half a point inside the case's bottom edge.
    static let feet = Region(rects: [
        Rect(x: 3.75, y: 14.5, width: 2.5, height: 1.5),
        Rect(x: 19.75, y: 14.5, width: 2.5, height: 1.5),
    ])

    /// Where the P's top-left cell sits: the 7 x 9 P centred on the case at
    /// one point per cell, no gap.
    static let pOrigin = (x: 9.5, y: 3.0)

    /// The P's cells, one point each — what the online state knocks out.
    static let pCells = Region(rects: (0..<PixelP.height).flatMap { row in
        (0..<PixelP.width).compactMap { col in
            PixelP.isLit(col: col, row: row)
                ? Rect(x: pOrigin.x + Double(col), y: pOrigin.y + Double(row), width: 1, height: 1)
                : nil
        }
    })

    /// The P as a contour: its silhouette on a half-point grid, every cell
    /// with a 4-neighbour outside the silhouette filled as a 0.5-pt square.
    static let pContour: Region = {
        let inside = { (i: Int, j: Int) in PixelP.isLit(col: i >= 0 ? i / 2 : -1, row: j >= 0 ? j / 2 : -1) }
        var squares: [Rect] = []
        for j in 0..<PixelP.height * 2 {
            for i in 0..<PixelP.width * 2 where inside(i, j) {
                guard !inside(i - 1, j) || !inside(i + 1, j) || !inside(i, j - 1) || !inside(i, j + 1)
                else { continue }
                squares.append(Rect(x: pOrigin.x + Double(i) * 0.5, y: pOrigin.y + Double(j) * 0.5,
                                    width: 0.5, height: 0.5))
            }
        }
        return Region(rects: squares)
    }()

    /// The half-point bezel ring the online state knocks out, the spec's
    /// `strokeRect(2.25, 2.25, 21.5, 10.5)` at width 0.5.
    static let bezel = Region(
        rects: [Rect(x: 2, y: 2, width: 22, height: 11)],
        holes: [Rect(x: 2.5, y: 2.5, width: 21, height: 10)]
    )

    /// The offline square, 4 x 4 pt on the case's top-right corner, and the
    /// 1-pt moat cleared round it first so it reads apart from the stroke.
    static let moat = Region(rects: [Rect(x: 21.5, y: -1.5, width: 6, height: 6)])
    static let badge = Region(rects: [Rect(x: 22.5, y: -0.5, width: 4, height: 4)])

    /// Everything above sits on the canvas shifted by this much.
    static let shift = (x: 1.0, y: 0.5)

    // MARK: Drawing

    enum Paint: Equatable {
        case ink
        case red
        /// Cut back to transparent, by the region's coverage.
        case clear
    }

    /// One step of a drawing, applied in order over what came before.
    struct Layer {
        let region: Region
        let paint: Paint
    }

    /// A state as the ordered steps that draw it — the oracle's own order.
    static func layers(_ state: State) -> [Layer] {
        switch state {
        case .online:
            [Layer(region: feet, paint: .ink), Layer(region: caseFill, paint: .ink),
             Layer(region: pCells, paint: .clear), Layer(region: bezel, paint: .clear)]
        case .offline:
            [Layer(region: feet, paint: .ink), Layer(region: caseStroke, paint: .ink),
             Layer(region: pContour, paint: .ink),
             Layer(region: moat, paint: .clear), Layer(region: badge, paint: .red)]
        case .empty:
            // Not approved in the browser: the rule the user's clock had, the
            // device drawn and not its contents — no P, no badge.
            [Layer(region: feet, paint: .ink), Layer(region: caseStroke, paint: .ink)]
        }
    }

    /// A device pixel: 0xRRGGBB and a straight (not premultiplied) alpha.
    struct Pixel: Equatable {
        let rgb: UInt32
        let alpha: UInt8

        static let clear = Pixel(rgb: 0, alpha: 0)
    }

    /// The glyph as device pixels, rows top-down.
    struct Raster: Equatable {
        let width: Int
        let height: Int
        let pixels: [Pixel]

        func pixel(x: Int, y: Int) -> Pixel {
            pixels[y * width + x]
        }
    }

    /// A pure function of its arguments: every device pixel composited from
    /// the exact area each layer covers of it, so @1x, @2x and @3x all come
    /// from the one geometry and a half point lands as a half-covered pixel,
    /// never as a resampled one.
    static func raster(_ state: State, appearance: Appearance, scale: Int) -> Raster {
        precondition(scale >= 1, "a point is at least one device pixel")
        let w = width * scale, h = height * scale, unit = 1 / Double(scale)
        let steps = layers(state).map { layer in
            (layer.region.offsetBy(dx: shift.x, dy: shift.y), layer.paint)
        }
        var pixels: [Pixel] = []
        pixels.reserveCapacity(w * h)
        for y in 0..<h {
            for x in 0..<w {
                let cell = Rect(x: Double(x) * unit, y: Double(y) * unit, width: unit, height: unit)
                // Premultiplied red, green, blue and alpha, 0...1.
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                for (region, paint) in steps {
                    let c = region.coverage(of: cell)
                    guard c > 0 else { continue }
                    switch paint {
                    case .clear:
                        r *= 1 - c; g *= 1 - c; b *= 1 - c; a *= 1 - c
                    case .ink, .red:
                        let hex = paint == .red ? red : appearance.ink
                        r = channel(hex, 16) * c + r * (1 - c)
                        g = channel(hex, 8) * c + g * (1 - c)
                        b = channel(hex, 0) * c + b * (1 - c)
                        a = c + a * (1 - c)
                    }
                }
                pixels.append(straight(r: r, g: g, b: b, a: a))
            }
        }
        return Raster(width: w, height: h, pixels: pixels)
    }

    static func channel(_ hex: UInt32, _ shift: UInt32) -> Double {
        Double((hex >> shift) & 0xFF) / 255
    }

    /// Premultiplied 0...1 components as an 8-bit straight pixel.
    static func straight(r: Double, g: Double, b: Double, a: Double) -> Pixel {
        let alpha = UInt8((a * 255).rounded())
        guard alpha > 0 else { return .clear }
        let byte = { (v: Double) in UInt32(min(255, max(0, (v / a * 255).rounded()))) }
        return Pixel(rgb: byte(r) << 16 | byte(g) << 8 | byte(b), alpha: alpha)
    }
}
