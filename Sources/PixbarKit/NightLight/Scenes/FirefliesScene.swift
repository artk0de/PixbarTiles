/// Fireflies: a dark field where some twenty fireflies wander on slow loops
/// and glow up and out one by one; a big one wears a dim amber halo — the
/// port of `nightlight/fireflies.py`.
///
/// Every colour is an amber picked on the panel: a firefly never dims
/// through red, and its core stays short of gold.
enum FirefliesScene {
    static let frameMs = 100
    static let cycleFrames = 240      // 24 s at 1×

    /// The dimmest amber is red 100 + green 40; below that green reads yellow-green.
    static let glow: [RGB] = [.black, RGB(r: 100, g: 40, b: 0), RGB(r: 160, g: 40, b: 0), RGB(r: 192, g: 72, b: 0),
                              RGB(r: 255, g: 72, b: 0), RGB(r: 255, g: 100, b: 0)]

    struct Fly {
        let cx, cy, ax, ay, kx, ky, px, py, kp, pp: Int
        let big: Bool
    }

    // (centre, reach, turns a loop x / y, phases x / y, glows a loop, glow phase, big)
    static let flies: [Fly] = [
        Fly(cx: 6, cy: 11, ax: 4, ay: 2, kx: 1, ky: 2, px: 0, py: 64, kp: 3, pp: 0, big: true),
        Fly(cx: 21, cy: 4, ax: 6, ay: 2, kx: 1, ky: 1, px: 90, py: 10, kp: 2, pp: 150, big: true),
        Fly(cx: 34, cy: 11, ax: 5, ay: 3, kx: 2, ky: 1, px: 30, py: 200, kp: 3, pp: 90, big: true),
        Fly(cx: 46, cy: 5, ax: 4, ay: 2, kx: 1, ky: 2, px: 170, py: 120, kp: 2, pp: 40, big: true),
        Fly(cx: 2, cy: 3, ax: 2, ay: 1, kx: 1, ky: 1, px: 40, py: 0, kp: 4, pp: 20, big: false),
        Fly(cx: 13, cy: 7, ax: 4, ay: 2, kx: 1, ky: 2, px: 200, py: 40, kp: 3, pp: 200, big: false),
        Fly(cx: 15, cy: 14, ax: 5, ay: 1, kx: 1, ky: 1, px: 10, py: 100, kp: 2, pp: 110, big: false),
        Fly(cx: 27, cy: 9, ax: 5, ay: 2, kx: 2, ky: 1, px: 120, py: 60, kp: 4, pp: 60, big: false),
        Fly(cx: 30, cy: 2, ax: 4, ay: 1, kx: 1, ky: 2, px: 80, py: 30, kp: 3, pp: 240, big: false),
        Fly(cx: 40, cy: 13, ax: 4, ay: 1, kx: 1, ky: 1, px: 220, py: 180, kp: 2, pp: 170, big: false),
        Fly(cx: 43, cy: 9, ax: 3, ay: 2, kx: 2, ky: 1, px: 60, py: 90, kp: 3, pp: 130, big: false),
        Fly(cx: 50, cy: 13, ax: 2, ay: 2, kx: 1, ky: 1, px: 140, py: 220, kp: 4, pp: 80, big: false),
        Fly(cx: 10, cy: 2, ax: 3, ay: 1, kx: 2, ky: 1, px: 5, py: 86, kp: 4, pp: 238, big: true),
        Fly(cx: 26, cy: 13, ax: 3, ay: 2, kx: 1, ky: 2, px: 222, py: 177, kp: 2, pp: 57, big: true),
        Fly(cx: 4, cy: 7, ax: 2, ay: 2, kx: 2, ky: 1, px: 139, py: 226, kp: 3, pp: 179, big: false),
        Fly(cx: 18, cy: 10, ax: 4, ay: 1, kx: 2, ky: 1, px: 106, py: 203, kp: 2, pp: 60, big: false),
        Fly(cx: 23, cy: 1, ax: 5, ay: 1, kx: 2, ky: 2, px: 220, py: 74, kp: 3, pp: 181, big: false),
        Fly(cx: 31, cy: 6, ax: 5, ay: 2, kx: 2, ky: 1, px: 66, py: 65, kp: 4, pp: 252, big: false),
        Fly(cx: 37, cy: 3, ax: 3, ay: 2, kx: 2, ky: 2, px: 250, py: 142, kp: 2, pp: 242, big: false),
        Fly(cx: 38, cy: 8, ax: 5, ay: 1, kx: 2, ky: 2, px: 101, py: 19, kp: 3, pp: 119, big: false),
        Fly(cx: 48, cy: 1, ax: 2, ay: 1, kx: 1, ky: 2, px: 228, py: 174, kp: 3, pp: 107, big: false),
        Fly(cx: 20, cy: 7, ax: 2, ay: 2, kx: 2, ky: 2, px: 213, py: 65, kp: 3, pp: 175, big: false),
    ]
    /// The triangle below zero is dark: lit 55 % of each glow.
    static let litFrom = -800

    static func design(_ step: Int) -> RGB { RGB(r: step * 20 + 10, g: 0, b: 0) }

    static func tint(_ r: Int) -> RGB {
        r >= 20 ? glow[min(glow.count - 1, IntMath.floorDiv(r, 20))] : .black
    }

    static let scene: AnimatedScene = {
        let layers = flies.map { fly -> AnimationLayer in
            var pixels = [AnimationPixel(x: fly.cx, y: fly.cy, colour: design(fly.big ? 5 : 3))]
            if fly.big {
                pixels += [(1, 0), (-1, 0), (0, 1), (0, -1)].map {
                    AnimationPixel(x: fly.cx + $0.0, y: fly.cy + $0.1, colour: design(1))
                }
            }
            let wander: AnimationLayer.Offset = { frame, n in
                (dx: IntMath.truncDiv(fly.ax * IntMath.sin[IntMath.phase(frame, n, fly.kx, fly.px)], 127),
                 dy: IntMath.truncDiv(fly.ay * IntMath.sin[IntMath.phase(frame, n, fly.ky, fly.py)], 127))
            }
            let pulse: AnimationLayer.Multiplier = { frame, n, _, _, _ in
                max(0, IntMath.ramp(frame, n, fly.kp, fly.pp, litFrom, 1000))
            }
            return AnimationLayer(name: "fly\(fly.cx)", pixels: pixels, multiplier: pulse, offset: wander,
                                  key: "flyMotion")
        }
        return AnimatedScene(id: "fireflies", frameMs: frameMs, cycleFrames: cycleFrames, layers: layers, tint: tint)
    }()
}
