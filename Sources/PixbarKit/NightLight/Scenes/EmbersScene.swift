/// Embers: a bed of coals along the bottom rows, its glowing pixels flickering
/// a heat step and back, and sparks leaving the bed, rising a few rows and
/// cooling on the way — the port of `nightlight/embers.py`.
///
/// A pixel's design red names its heat step (`step * 20 + 10`), so the
/// multiplier moves it between whole steps and never between hues the panel
/// was not shown.
enum EmbersScene {
    static let frameMs = 100
    static let cycleFrames = 200      // 20 s at 1×
    static let rowTime = 4            // 1× frames a spark takes per row

    /// The ambers picked on the TC002 2026-09-29; heat 1 is the crust, 8 the core.
    static let heat: [RGB] = [.black, RGB(r: 40, g: 0, b: 0), RGB(r: 100, g: 0, b: 0), RGB(r: 160, g: 0, b: 0),
                              RGB(r: 192, g: 0, b: 0), RGB(r: 255, g: 40, b: 0), RGB(r: 255, g: 72, b: 0),
                              RGB(r: 255, g: 100, b: 0), RGB(r: 255, g: 144, b: 0)]

    static let bedY = 10
    static let bed = [
        "....................................................",
        "..........................21........................",
        ".11........11......1111211231.......................",
        "1221......124......2222234334...111111212111111.2211",
        "2686.1121.866111211434368643511133222242222242212222",
        "4456133331447368645544444668633644444464544464455544",
    ]

    /// (x, sparks a loop, start in 1× frames, rows it climbs, columns it drifts)
    static let sparks: [(x: Int, k: Int, start: Int, rise: Int, drift: Int)] = [
        (3, 4, 7, 5, 0), (10, 2, 31, 8, 1), (17, 5, 12, 4, 0), (24, 4, 40, 7, -1),
        (27, 2, 83, 9, 0), (33, 5, 22, 6, 1), (39, 4, 3, 5, 0), (44, 2, 58, 8, -1),
        (49, 5, 29, 6, 0), (14, 4, 19, 6, 0),
    ]
    static let sparkHeat = 7          // a spark leaves the bed at heat 7 and cools to 2
    /// From this heat up every pixel flickers two steps deep: a still
    /// yellow-amber dot read as a fault.
    static let hot = 6

    static func design(_ step: Int) -> RGB { RGB(r: step * 20 + 10, g: 0, b: 0) }

    /// The multiplier that shows a pixel of heat `from` at `to`.
    static func perMille(_ to: Int, _ from: Int) -> Int {
        to != 0 ? IntMath.floorDiv((to * 20 + 10) * 1000, from * 20 + 10) : 0
    }

    static func tint(_ r: Int) -> RGB {
        r >= 20 ? heat[min(heat.count - 1, IntMath.floorDiv(r, 20))] : .black
    }

    static let scene: AnimatedScene = {
        var inks: [Character: RGB] = [:]
        for s in 1...8 { inks[Character(String(s))] = design(s) }
        let bedPixels = AnimatedScene.mask(bed, inks, x0: 0, y0: bedY)
        var tops: [Int: Int] = [:]
        for p in bedPixels { tops[p.x] = min(tops[p.x] ?? p.y, p.y) }

        let flicker: AnimationLayer.Multiplier = { frame, n, i, x, y in
            let step = IntMath.floorDiv(bedPixels[i].colour.r, 20)
            let h = (x * 73 + y * 151) & 255
            let low: Int
            if step >= hot {
                low = perMille(step - 2, step)
            } else if step < 2 || h % 3 != 0 {
                return 1000
            } else {
                low = perMille(step - 1, step)
            }
            return IntMath.swing(frame, n, 2 + h % 4, h, low - 150, 1000 + 40)
        }
        var layers = [AnimationLayer(name: "bed", pixels: bedPixels, multiplier: flicker, key: "emberGlow")]

        for spark in sparks {
            let y0 = tops[spark.x]! - 1
            let period = cycleFrames / spark.k
            let climbed: @Sendable (Int, Int) -> Int? = { frame, n in
                let u = IntMath.floorMod(IntMath.floorDiv(frame * cycleFrames, n) + spark.start, period)
                let s = u / rowTime
                return s < spark.rise ? s : nil
            }
            let offset: AnimationLayer.Offset = { frame, n in
                guard let s = climbed(frame, n) else { return (dx: -99, dy: -99) }
                return (dx: IntMath.floorDiv(spark.drift * s, spark.rise), dy: -s)
            }
            let glow: AnimationLayer.Multiplier = { frame, n, i, _, _ in
                guard let s = climbed(frame, n) else { return 0 }
                let head = sparkHeat - IntMath.floorDiv(5 * s, spark.rise)
                if i == 0 { return perMille(head, sparkHeat) }
                return s != 0 ? perMille(max(0, head - 4), sparkHeat) : 0
            }
            let pixels = [AnimationPixel(x: spark.x, y: y0, colour: design(sparkHeat)),
                          AnimationPixel(x: spark.x, y: y0 + 1, colour: design(sparkHeat))]
            layers.append(AnimationLayer(name: "spark\(spark.x)", pixels: pixels, multiplier: glow,
                                         offset: offset, key: "sparks"))
        }
        return AnimatedScene(id: "embers", frameMs: frameMs, cycleFrames: cycleFrames, layers: layers, tint: tint)
    }()
}
