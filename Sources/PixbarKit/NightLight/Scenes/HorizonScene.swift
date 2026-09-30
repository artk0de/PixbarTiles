/// Warm horizon: the sheet's panel pixel for pixel — a horizon line along the
/// bottom, the band fading to dark red within three rows, a sun gone under at
/// x 8…14 — lit by slow light: a two-sine wave lifts or drops a pixel above
/// the line one step, and the sun's dome warms a step and cools back once a
/// loop. The port of `nightlight/horizon.py`.
///
/// Solid steps only: dithering read as dots on this panel, and a whole area
/// changing level at once read as flicker.
enum HorizonScene {
    static let frameMs = 250          // 4 frames a second is plenty for light this slow
    static let cycleFrames = 144      // 36 s at 1×: the waves turn twice and once, whole

    /// The approved colours, 1 … 7, dimmest first.
    static let levels: [RGB] = [RGB(r: 40, g: 0, b: 0), RGB(r: 100, g: 0, b: 0), RGB(r: 160, g: 40, b: 0),
                                RGB(r: 192, g: 40, b: 0), RGB(r: 255, g: 72, b: 0), RGB(r: 255, g: 100, b: 0),
                                RGB(r: 255, g: 144, b: 0)]

    static let bandY = 11
    static let band = [
        ".......11123222221..................................",
        "11.1.11122333222211.....11..........................",
        "221222222344444322222212222211111.1...1221..1.......",
        "2332223445667655533222234443222222111234322212222222",
        "5556566667777777666554555555545554444444444444444444",
    ]

    /// (SIN steps per column, turns a loop, sign, share per mille).
    static let waves: [(step: Int, turns: Int, sign: Int, share: Int)] = [(4, 2, 1, 700), (9, 1, -1, 300)]
    static let peak = 780
    static let rowShift = 23          // the fronts lean, so a column's rows never step together
    static let jitterSpread = 160     // neighbours cross a threshold frames apart

    static let sunX = 12, sunReach = 6
    static let sunStart = 150, sunSpread = 130

    static func base(_ x: Int, _ y: Int) -> Int {
        let d = y - bandY
        guard 0 <= d, d < band.count else { return 0 }
        let ch = Array(band[d])[x]
        return ch == "." ? 0 : ch.wholeNumberValue!
    }

    static func wave(_ frame: Int, _ n: Int, _ x: Int, _ y: Int) -> Int {
        var s = 0
        for w in waves {
            let index = (x * w.step + y * rowShift + w.sign * IntMath.phase(frame, n, w.turns)) & 255
            s += IntMath.floorDiv(w.share * IntMath.sin[index], 127)
        }
        return s + IntMath.jitter(x, y, jitterSpread)
    }

    /// The level a pixel is drawn at, 0 for black.
    static func drawn(_ frame: Int, _ n: Int, _ x: Int, _ y: Int) -> Int {
        let lv = base(x, y)
        if y == AnimatedScene.height - 1 || lv == 0 { return lv }   // the horizon line and the sky never change
        let v = wave(frame, n, x, y)
        var shift = v > peak ? 1 : v < -peak ? -1 : 0
        let off = max(abs(x - sunX), AnimatedScene.height - 2 - y)
        let warmAt = sunStart + sunSpread * off
            + IntMath.floorDiv(IntMath.jitter(y, x, jitterSpread) * sunSpread, 2 * jitterSpread)
        if off <= sunReach, IntMath.swing(frame, n, 1, 0, -1000, 1000) > warmAt { shift += 1 }
        return max(1, min(levels.count, lv + max(-1, min(1, shift))))   // never more than a step off the sheet
    }

    static func design(_ lv: Int) -> RGB { RGB(r: lv * 20 + 10, g: 0, b: 0) }

    static func tint(_ r: Int) -> RGB {
        let lv = IntMath.floorDiv(r, 20)
        return lv >= 1 ? levels[min(levels.count, lv) - 1] : .black
    }

    static let scene: AnimatedScene = {
        let top = levels.count
        var pixels: [AnimationPixel] = []
        for y in bandY..<AnimatedScene.height {
            for x in 0..<AnimatedScene.width where base(x, y) != 0 {
                pixels.append(AnimationPixel(x: x, y: y, colour: design(top)))
            }
        }
        let light: AnimationLayer.Multiplier = { frame, n, _, x, y in
            let lv = drawn(frame, n, x, y)
            return lv != 0 ? IntMath.floorDiv((lv * 20 + 10) * 1000, top * 20 + 10) : 0
        }
        return AnimatedScene(id: "horizon", frameMs: frameMs, cycleFrames: cycleFrames,
                             layers: [AnimationLayer(name: "band", pixels: pixels, multiplier: light, key: "horizonLight")],
                             tint: tint)
    }()
}
