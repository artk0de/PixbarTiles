/// Fireplace: the sheet's small fire pixel for pixel, its core held at amber
/// (no yellow centre at night), set alive — the port of
/// `nightlight/fireplace.py`:
///
/// - embers: the bottom two rows, each swinging a step and back on its own
///   2–5 s period;
/// - flames: every column above them slides its cells −1 … +2 rows on an
///   energy that drifts smoothly along the row, so the tongues rise and fall;
/// - sparks: at most three single pixels, each rising a row every 400 ms from
///   the core's top, fading and drifting aside.
enum FireplaceScene {
    static let frameMs = 100          // 10 frames a second, as a fire asks
    static let cycleFrames = 200      // 20 s at 1×

    /// The approved colours, 1 … 8: pure reds first, then the ambers.
    static let levels: [RGB] = [RGB(r: 40, g: 0, b: 0), RGB(r: 100, g: 0, b: 0), RGB(r: 160, g: 0, b: 0),
                                RGB(r: 192, g: 0, b: 0), RGB(r: 160, g: 40, b: 0), RGB(r: 192, g: 40, b: 0),
                                RGB(r: 255, g: 72, b: 0), RGB(r: 255, g: 100, b: 0)]
    static let topLevel = 8           // 255/100: the sheet's near-yellow core held at amber

    static let fireY = 6
    static let fire = [
        ".....................3......3.......................",
        ".....................2..541.3.......................",
        "........................56331.3.....................",
        "......................22.2651.5.....................",
        "..................22..2324875.3.1...................",
        "..................33.1323688614.2...1...............",
        "..................22.233488862312...2...............",
        "..............2.126653668888868342221...............",
        "............122328777318888752825763213..1..........",
        "............122.28.22.2773652.6.586...3....1........",
    ]
    static let emberRows = 2
    static let emberTurns = [4, 5, 7, 9, 6, 8]    // turns a loop: 2.2 … 5 s a swing

    static let energy: [(turns: Int, weight: Int)] = [(7, 1000), (13, 500)]
    static let roll = 37              // SIN steps of phase from one column to the next
    static let liftBias = 300, liftScale = 750

    /// (slot turns a loop, first frame, column, drift over its rise)
    static let sparks: [(turns: Int, start: Int, x0: Int, drift: Int)] = [(4, 11, 26, 1), (2, 67, 29, -1), (5, 30, 27, 1)]
    static let sparkRow = 4           // frames a row: 400 ms
    static let sparkLevels = [7, 6, 3, 2]

    static let height = AnimatedScene.height

    static func base(_ x: Int, _ y: Int) -> Int {
        let d = y - fireY
        guard 0 <= d, d < fire.count else { return 0 }
        let ch = Array(fire[d])[x]
        return ch == "." ? 0 : min(topLevel, ch.wholeNumberValue!)
    }

    /// Rows the column's cells slide up this frame, −1 … +2.
    static func lift(_ frame: Int, _ n: Int, _ x: Int) -> Int {
        var e = 0
        for part in energy {
            let index = (IntMath.phase(frame, n, part.turns) + x * roll * part.turns) & 255
            e += IntMath.floorDiv(part.weight * IntMath.sin[index], 127)
        }
        return max(-1, min(2, IntMath.truncDiv(e + liftBias, liftScale)))
    }

    /// A flame cell's level: the sheet's cell `lift` rows below it.
    static func flameLevel(_ frame: Int, _ n: Int, _ x: Int, _ y: Int) -> Int {
        let root = height - 1 - emberRows
        let src = y + lift(frame, n, x)
        return src >= fireY ? base(x, min(root, src)) : 0
    }

    static func design(_ lv: Int) -> RGB { RGB(r: lv * 20 + 10, g: 0, b: 0) }

    static func tint(_ r: Int) -> RGB {
        let lv = IntMath.floorDiv(r, 20)
        return lv >= 1 ? levels[min(levels.count, lv) - 1] : .black
    }

    static func perMille(_ lv: Int, _ of: Int) -> Int {
        lv != 0 ? IntMath.floorDiv((lv * 20 + 10) * 1000, of * 20 + 10) : 0
    }

    /// The row above the column's top flame cell this frame.
    static func topOf(_ frame: Int, _ n: Int, _ x: Int) -> Int {
        for y in (fireY - 2)..<(height - emberRows) where flameLevel(frame, n, x, y) != 0 {
            return y - 1
        }
        return height - emberRows - 1
    }

    static let scene: AnimatedScene = {
        let embers = ((height - emberRows)..<height).flatMap { y in
            (0..<AnimatedScene.width).filter { base($0, y) != 0 }
                .map { AnimationPixel(x: $0, y: y, colour: design(base($0, y))) }
        }
        let smoulder: AnimationLayer.Multiplier = { frame, n, i, x, y in
            let lv = IntMath.floorDiv(embers[i].colour.r, 20)
            let turns = emberTurns[(x + y) % emberTurns.count]
            let s = IntMath.swing(frame, n, turns, (x * 97 + y * 41) & 255, -1000, 1000)
            let step = s > 600 ? 1 : s < -600 ? -1 : 0
            return perMille(max(1, min(topLevel, lv + step)), lv)
        }

        let cols = (0..<AnimatedScene.width).filter { x in
            ((fireY)..<(height - emberRows)).contains { base(x, $0) != 0 }
        }
        var flames: [AnimationPixel] = []
        for y in (fireY - 2)..<(height - emberRows) {
            for x in cols { flames.append(AnimationPixel(x: x, y: y, colour: design(topLevel))) }
        }
        let burn: AnimationLayer.Multiplier = { frame, n, _, x, y in
            perMille(flameLevel(frame, n, x, y), topLevel)
        }

        var layers = [AnimationLayer(name: "embers", pixels: embers, multiplier: smoulder, key: "flames"),
                      AnimationLayer(name: "flames", pixels: flames, multiplier: burn, key: "flames")]
        for spark in sparks {
            let life: @Sendable (Int, Int) -> Int? = { frame, n in
                let u = IntMath.floorMod(IntMath.floorDiv(frame * cycleFrames, n) + spark.start, cycleFrames / spark.turns)
                let s = u / sparkRow
                return s < sparkLevels.count ? s : nil
            }
            let rise: AnimationLayer.Offset = { frame, n in
                guard let s = life(frame, n) else { return (dx: -99, dy: -99) }
                return (dx: IntMath.floorDiv(spark.drift * s, sparkLevels.count - 1), dy: topOf(frame, n, spark.x0) - s)
            }
            let fade: AnimationLayer.Multiplier = { frame, n, _, _, _ in
                guard let s = life(frame, n) else { return 0 }
                return perMille(sparkLevels[s], sparkLevels[0])
            }
            layers.append(AnimationLayer(name: "spark\(spark.x0)",
                                         pixels: [AnimationPixel(x: spark.x0, y: 0, colour: design(sparkLevels[0]))],
                                         multiplier: fade, offset: rise, key: "sparks"))
        }
        return AnimatedScene(id: "fireplace", frameMs: frameMs, cycleFrames: cycleFrames, layers: layers, tint: tint)
    }()
}
