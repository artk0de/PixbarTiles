/// Red Moon: a crescent leaning right, amber at its inner limb cooling to dark
/// red at its back, a sky of dim stars, and the sheet's cloud bank drifting
/// right by whole pixels, one panel width a loop, through a pool of moonlight
/// fixed under the crescent and drawn in the crescent's own colours — the
/// port of `nightlight/redmoon.py`.
enum RedMoonScene {
    static let frameMs = 150
    static let cycleFrames = 208      // 31.2 s at 1×: 4 frames a pixel of drift
    static let width = AnimatedScene.width

    /// The crescent (`make_moon.py`): B the bright inner limb, M the body,
    /// T the thin edges and horn tips, g the faint rim.
    static let moonX = 3, moonY = 1
    static let moon = [
        "...gMT.....",
        "..TMB......",
        ".gMBT......",
        ".MMBT......",
        ".MMBT......",
        ".MMBM......",
        ".MMMBT.....",
        ".gMMMBTg...",
        "..TMMMBBBT.",
        "...gMMMMg..",
    ]
    /// Graded by steps from the inner limb: 255/100, 255/72, 192/40, red 160;
    /// thin edges 144, the faint rim 100.
    static let moonInk: [Character: RGB] = [
        "0": RGB(r: 185, g: 100, b: 0), "1": RGB(r: 185, g: 72, b: 0), "2": RGB(r: 120, g: 40, b: 0),
        "3": RGB(r: 64, g: 0, b: 0), "T": RGB(r: 36, g: 0, b: 0), "g": RGB(r: 20, g: 0, b: 0),
    ]

    /// (x, y, peak red, goes out)
    static let stars: [(x: Int, y: Int, peak: Int, goesOut: Bool)] = [
        (1, 2, 46, false), (0, 6, 90, false), (2, 9, 40, true),
        (16, 1, 60, false), (21, 4, 46, true), (16, 9, 90, false), (20, 13, 42, false),
        (24, 11, 40, true), (27, 2, 110, false), (30, 7, 44, false), (34, 12, 40, true),
        (37, 4, 62, false), (40, 9, 96, false), (44, 0, 50, false), (45, 6, 40, false),
        (48, 3, 104, false), (50, 11, 44, false), (43, 13, 38, false),
    ]
    static let starCycles = [3, 4, 5, 4, 3, 5]   // 10, 7.5 and 6 s at 1×
    static let starLow = -350                     // the sine dips below zero: dark for a while

    /// Moonlight on the clouds: distance from the limb's foot, a column
    /// counting 4 to the left and 6 to the right (from `rightFrom`), a row 3;
    /// one ramp step per band of 14 and per ring under the bank's edge.
    static let moonCX = 7, glowY = 10
    static let rightFrom = 8
    static let stepLeft = 4, stepRight = 6, stepY = 3
    static let firstStep = 1, band = 14
    static let lit = 200              // design reds from here up name a ramp step, 10 apart
    static let near = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0)]   // above, diagonally above, beside
    /// (from distance, body cap, edge cap), farthest first: out of the light the bank darkens.
    static let shades: [(far: Int, top: Int, edgeTop: Int)] = [(150, 8, 20), (100, 20, 20), (70, 36, 36)]

    /// The sheet's bank cell for cell; each ink is a design red, 4 per step.
    static let cloudInks = Array("..23456789ABCDEFG")
    static let frontY = 10
    static let front = [
        "A75.................................................",
        "B965556666543332222................................9",
        "9A8765555544333332222.............................68",
        "79AA86555544444554322222.........................456",
        "457998655554456765433333223443454222..........223445",
        "23468876555556897655444333466556533222.....222333334",
    ]

    struct Cell: Hashable { let x: Int, y: Int }

    /// The mask with every limb and body pixel (B, M) replaced by its steps
    /// from the inner limb, 0…3 (3 and beyond are the back); T and g stay.
    static func graded(_ rows: [String]) -> [String] {
        let grid = rows.map(Array.init)
        var cells = Set<Cell>()
        var steps: [Cell: Int] = [:]
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                cells.insert(Cell(x: x, y: y))
                if ch == "B" { steps[Cell(x: x, y: y)] = 0 }
            }
        }
        var frontier = Array(steps.keys)
        while !frontier.isEmpty {
            var next: [Cell] = []
            for c in frontier {
                for q in [Cell(x: c.x + 1, y: c.y), Cell(x: c.x - 1, y: c.y), Cell(x: c.x, y: c.y + 1), Cell(x: c.x, y: c.y - 1)]
                where cells.contains(q) && steps[q] == nil {
                    steps[q] = steps[c]! + 1
                    next.append(q)
                }
            }
            frontier = next
        }
        return grid.enumerated().map { y, row in
            String(row.enumerated().map { x, ch in
                "BM".contains(ch) ? Character(String(min(3, steps[Cell(x: x, y: y)]!))) : ch
            })
        }
    }

    /// A bright star burns amber and cools to red as it dims; a faint one stays red.
    static func starGreen(_ peak: Int) -> Int { peak >= 90 ? 72 : peak >= 60 ? 40 : 0 }

    /// The crescent's colours from its inner limb to its faint rim, as the panel draws them.
    static let moonRamp: [RGB] = "0123Tg".map { key in
        let ink = moonInk[key]!
        let r = PanelLevels.red(ink.r)
        return RGB(r: r, g: PanelLevels.amber(r, ink.g), b: 0)
    }

    /// A cloud pixel's colour: the crescent's ramp step when the multiplier
    /// lifted it to `lit` or above, else its own red.
    static func moonlit(_ r: Int) -> RGB {
        r >= lit ? moonRamp[min(moonRamp.count - 1, IntMath.floorDiv(r - lit, 10))] : RGB(r: PanelLevels.red(r), g: 0, b: 0)
    }

    /// The panel's own red for a design red — pure red.
    static func red(_ r: Int) -> RGB { RGB(r: PanelLevels.red(r), g: 0, b: 0) }

    static let scene: AnimatedScene = {
        let moonPixels = AnimatedScene.mask(graded(moon), moonInk, x0: moonX, y0: moonY)
        let starPixels = stars.map { AnimationPixel(x: $0.x, y: $0.y, colour: RGB(r: $0.peak, g: starGreen($0.peak), b: 0)) }
        var cloudInk: [Character: RGB] = [:]
        for (i, ch) in cloudInks.enumerated() where ch != "." { cloudInk[ch] = RGB(r: 4 * i, g: 0, b: 0) }
        let clouds = AnimatedScene.mask(front, cloudInk, x0: 0, y0: frontY)

        let filled = Set(clouds.map { Cell(x: $0.x, y: $0.y) })
        var ring: [Cell: Int] = [:]                       // rings under the bank's edge (the bank wraps)
        for p in clouds where near.contains(where: { !filled.contains(Cell(x: IntMath.floorMod(p.x + $0.0, width), y: p.y + $0.1)) }) {
            ring[Cell(x: p.x, y: p.y)] = 0
        }
        for k in 1..<moonRamp.count {
            for p in clouds where ring[Cell(x: p.x, y: p.y)] == nil {
                if near.contains(where: { ring[Cell(x: IntMath.floorMod(p.x + $0.0, width), y: p.y + $0.1)] == k - 1 }) {
                    ring[Cell(x: p.x, y: p.y)] = k
                }
            }
        }
        let rings = ring
        let own = clouds.map { PanelLevels.red($0.colour.r) }

        /// Whether ramp step `step` lights the i-th cloud pixel rather than
        /// leaving its own red: amber always does, a red only above its own.
        @Sendable func brighter(_ step: Int, _ i: Int) -> Bool {
            moonRamp[step].g > 0 || moonRamp[step].r > own[i]
        }

        let twinkle: AnimationLayer.Multiplier = { frame, n, i, _, _ in
            let low = stars[i].goesOut ? starLow : 200
            return max(0, IntMath.swing(frame, n, starCycles[i % starCycles.count], (i * 97) & 255, low, 1000))
        }
        let drift: AnimationLayer.Offset = { frame, n in (dx: IntMath.floorDiv(frame * width, n), dy: 0) }

        /// The i-th cloud pixel's own red, darkened as far from the moon as `dist` asks.
        @Sendable func shade(_ i: Int, _ dist: Int) -> Int {
            let p = clouds[i]
            let isEdge = rings[Cell(x: p.x, y: p.y)] == 0
            guard let cap = shades.first(where: { dist >= $0.far }).map({ isEdge ? $0.edgeTop : $0.top }),
                  PanelLevels.red(p.colour.r) > PanelLevels.red(cap) else { return 1000 }
            return IntMath.floorDiv(cap * 1000, p.colour.r) + 1
        }

        let cloudLight: AnimationLayer.Multiplier = { frame, n, i, x, y in
            let xx = IntMath.floorMod(x + drift(frame, n).dx, width)      // where the pixel is drawn now
            let dx = xx >= moonCX ? max(0, xx - rightFrom) * stepRight : (moonCX - xx) * stepLeft
            let dy = max(0, y - glowY) * stepY
            let dist = IntMath.isqrt(dx * dx + dy * dy)
            let step = rings[Cell(x: x, y: y)].map { firstStep + IntMath.floorDiv(dist, band) + $0 } ?? moonRamp.count
            if step >= moonRamp.count || !brighter(step, i) { return shade(i, dist) }
            return IntMath.floorDiv((lit + 10 * step) * 1000, clouds[i].colour.r) + 1
        }

        let layers = [
            AnimationLayer(name: "stars", pixels: starPixels, multiplier: twinkle, key: "starTwinkle"),
            AnimationLayer(name: "moon", pixels: moonPixels),
            AnimationLayer(name: "clouds", pixels: clouds, multiplier: cloudLight, offset: drift, key: "cloudMotion",
                           tint: moonlit),
        ]
        return AnimatedScene(id: "moon", frameMs: frameMs, cycleFrames: cycleFrames, layers: layers, tint: red)
    }()
}
