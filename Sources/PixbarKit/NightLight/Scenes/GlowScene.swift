/// Soft glow (ambient corner): the tail of a red-amber lamp standing just past
/// the bottom-right corner, drawn as the sheet's panel pixel for pixel on its
/// own LED grid — the port of `nightlight/glow.py`.
///
/// The motion, at 10 frames a second so each frame moves only a few pixels:
/// - brightness: a sine every 12 s, the glow a step brighter then dimmer than
///   the sheet, each pixel at its own moment, the nearest to the lamp first;
/// - radius: a sine every 24 s, the rim growing and drawing back one pixel;
/// - free dots: the scattered red dots flare a step and settle, each on its
///   own period, never going dark.
/// A pixel steps within its own family: red stays red, amber stays amber.
enum GlowScene {
    static let frameMs = 100
    static let cycleFrames = 240      // 24 s at 1×: two brightness breaths, one radius breath

    /// The approved colours, 1 … f, one ramp from the dimmest red to the corner's near-yellow.
    static let levels: [RGB] = [
        RGB(r: 40, g: 0, b: 0), RGB(r: 100, g: 0, b: 0), RGB(r: 144, g: 0, b: 0), RGB(r: 144, g: 40, b: 0),
        RGB(r: 160, g: 0, b: 0), RGB(r: 176, g: 0, b: 0), RGB(r: 176, g: 40, b: 0), RGB(r: 192, g: 0, b: 0),
        RGB(r: 192, g: 40, b: 0), RGB(r: 224, g: 40, b: 0), RGB(r: 224, g: 72, b: 0), RGB(r: 224, g: 100, b: 0),
        RGB(r: 255, g: 72, b: 0), RGB(r: 255, g: 100, b: 0), RGB(r: 255, g: 144, b: 0),
    ]

    /// The sheet's panel on the ramp (hex digits), one mock dot per cell.
    static let glowY = 0
    static let glow = [
        "....................................................",
        "....................................................",
        "....................................................",
        ".................................................3.1",
        "...............................................2...2",
        "..............................................1..122",
        "...........................................2...21222",
        ".............................................1222223",
        ".................................3.........221223338",
        ".........................................212222366aa",
        ".....................................151121233568aaa",
        "................................3..111123233558aaabd",
        ".............................31...131223335889aaddde",
        ".....................2...3..11121232333356aaabbdeeec",
        "...............2...2..1.1.1122322335568aaaaabdeeeeff",
        ".................1..121222333665668aaaadddefffffffff",
    ]

    static let lampX = 55, lampY = 18 // the lamp, just past the corner
    static let jitterSpread = 6       // quarter pixels of distance either way
    static let half = 2048            // half a turn of the sine, in 1/4096 turns
    static let brightTurns = 2, radiusTurns = 1
    static let first = 40, last = 960 // the earliest / latest moment a pixel steps
    static let sparse = 4             // a red pixel with this many dark neighbours is a free dot
    static let flareTurns = [2, 3, 4] // a free dot flares every 12, 8 or 6 s
    static let flare = 15             // frames a flare lasts: 1.5 s

    struct Cell: Hashable, Comparable {
        let x: Int
        let y: Int
        static func < (a: Cell, b: Cell) -> Bool { (a.x, a.y) < (b.x, b.y) }
    }

    static let width = AnimatedScene.width, height = AnimatedScene.height

    static func base(_ x: Int, _ y: Int) -> Int {
        let d = y - glowY
        guard 0 <= d, d < glow.count else { return 0 }
        let ch = Array(glow[d])[x]
        return ch == "." ? 0 : ch.hexDigitValue!
    }

    static let red = (1...levels.count).filter { levels[$0 - 1].g == 0 }
    static let amber = (1...levels.count).filter { levels[$0 - 1].g > 0 }

    static func darkAround(_ x: Int, _ y: Int) -> Int {
        var count = 0
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let (xx, yy) = (x + dx, y + dy)
                if 0 <= xx, xx < width, 0 <= yy, yy < height, base(xx, yy) == 0 { count += 1 }
            }
        }
        return count
    }

    static func isSparse(_ x: Int, _ y: Int) -> Bool { red.contains(base(x, y)) && darkAround(x, y) >= sparse }

    /// Each pixel's moment in a breath, 1/4096 turns: by its distance from the
    /// lamp plus a fixed jitter, spaced evenly by rank so the same few pixels
    /// change every frame.
    static func moments(_ cells: Set<Cell>) -> [Cell: Int] {
        func key(_ c: Cell) -> Int {
            let dx = c.x - lampX, dy = c.y - lampY
            return IntMath.isqrt(16 * (dx * dx + dy * dy)) + IntMath.jitter(c.x, c.y, jitterSpread)
        }
        let ranked = cells.sorted { (key($0), $0.x, $0.y) < (key($1), $1.x, $1.y) }
        let lastRank = max(1, ranked.count - 1)
        var at: [Cell: Int] = [:]
        for (i, c) in ranked.enumerated() { at[c] = first + IntMath.floorDiv((last - first) * i, lastRank) }
        return at
    }

    static let body: Set<Cell> = {
        var cells = Set<Cell>()
        for y in 0..<height {
            for x in 0..<width where base(x, y) != 0 && !isSparse(x, y) { cells.insert(Cell(x: x, y: y)) }
        }
        return cells
    }()
    /// The radius breath's pixels: the body's 40 red rim, which goes dark,
    /// and the dark dots touching a brighter body pixel, which light.
    static let shrink: Set<Cell> = body.filter { base($0.x, $0.y) == 1 && darkAround($0.x, $0.y) != 0 }
    static let grow: Set<Cell> = {
        var cells = Set<Cell>()
        for c in body where base(c.x, c.y) >= 2 {
            for dx in -1...1 {
                for dy in -1...1 {
                    let (xx, yy) = (c.x + dx, c.y + dy)
                    if 0 <= xx, xx < width, 0 <= yy, yy < height, base(xx, yy) == 0 { cells.insert(Cell(x: xx, y: yy)) }
                }
            }
        }
        return cells
    }()
    static let brightAt = moments(body)
    static let radiusAt = moments(shrink.union(grow))

    /// The loop's position in 1/4096 turns of a sine that turns `turns` times.
    static func turn(_ frame: Int, _ n: Int, _ turns: Int) -> Int {
        IntMath.floorMod(IntMath.floorDiv(frame * turns * 4096, n), 4096)
    }

    /// +1 while the sine is past this pixel's moment above zero, −1 below, else 0.
    static func side(_ t: Int, _ at: Int) -> Int {
        if at < t, t < half - at { return 1 }
        if half + at < t, t < 2 * half - at { return -1 }
        return 0
    }

    static func flared(_ frame: Int, _ n: Int, _ x: Int, _ y: Int) -> Int {
        let lv = base(x, y)
        let h = (IntMath.jitter(y, x, jitterSpread) + jitterSpread) * 7919 + x * 31 + y * 17   // a fixed per-dot hash
        let period = cycleFrames / flareTurns[h % flareTurns.count]
        let up = IntMath.floorMod(IntMath.floorDiv(frame * cycleFrames, n) + h, period) < flare
        return up ? red[min(red.count - 1, red.firstIndex(of: lv)! + 1)] : lv
    }

    /// The level a pixel is drawn at, 0 for black.
    static func drawn(_ frame: Int, _ n: Int, _ x: Int, _ y: Int) -> Int {
        let lv = base(x, y)
        let cell = Cell(x: x, y: y)
        if grow.contains(cell) {
            return side(turn(frame, n, radiusTurns), radiusAt[cell]!) > 0 ? 1 : 0
        }
        if lv == 0 { return 0 }
        if !body.contains(cell) { return flared(frame, n, x, y) }
        if shrink.contains(cell), side(turn(frame, n, radiusTurns), radiusAt[cell]!) < 0 { return 0 }
        let family = red.contains(lv) ? red : amber
        let i = family.firstIndex(of: lv)! + side(turn(frame, n, brightTurns), brightAt[cell]!)
        return family[max(0, min(family.count - 1, i))]
    }

    static func design(_ lv: Int) -> RGB { RGB(r: lv * 16 + 8, g: 0, b: 0) }   // 15 levels fit a red channel at 16 apart

    static func tint(_ r: Int) -> RGB {
        let lv = IntMath.floorDiv(r, 16)
        return lv >= 1 ? levels[min(levels.count, lv) - 1] : .black
    }

    static let scene: AnimatedScene = {
        let top = levels.count
        let lit = body.union(grow).sorted().map { AnimationPixel(x: $0.x, y: $0.y, colour: design(top)) }
        var dots: [AnimationPixel] = []
        for y in 0..<height {
            for x in 0..<width where base(x, y) != 0 && !body.contains(Cell(x: x, y: y)) {
                dots.append(AnimationPixel(x: x, y: y, colour: design(top)))
            }
        }
        let light: AnimationLayer.Multiplier = { frame, n, _, x, y in
            let lv = drawn(frame, n, x, y)
            return lv != 0 ? IntMath.floorDiv((lv * 16 + 8) * 1000, top * 16 + 8) : 0
        }
        return AnimatedScene(id: "glow", frameMs: frameMs, cycleFrames: cycleFrames,
                             layers: [AnimationLayer(name: "glow", pixels: lit, multiplier: light, key: "glowBreath"),
                                      AnimationLayer(name: "dots", pixels: dots, multiplier: light, key: "glowTwinkle")],
                             tint: tint)
    }()
}
