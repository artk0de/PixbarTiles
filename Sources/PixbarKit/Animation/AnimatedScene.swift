/// A colour in the engine's own integers — a design colour may exceed 255
/// before the multiplier and the clamp bring it back.
public struct RGB: Hashable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int
    public static let black = RGB(r: 0, g: 0, b: 0)
    public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
    var isLit: Bool { r != 0 || g != 0 || b != 0 }
}

public struct AnimationPixel: Sendable {
    public let x: Int
    public let y: Int
    public let colour: RGB
    public init(x: Int, y: Int, colour: RGB) { self.x = x; self.y = y; self.colour = colour }
}

/// A named group of pixels and how it moves — `nlengine.Layer`.
///
/// `multiplier` answers per mille for the index-th pixel, `offset` the
/// whole-pixel shift of the layer (x wraps round the panel, y clips). `key`
/// names the motion setting that stills it: it is then drawn at its base
/// colour where it stands. A layer's `tint` replaces the scene's.
public struct AnimationLayer: Sendable {
    public typealias Multiplier = @Sendable (_ frame: Int, _ n: Int, _ index: Int, _ x: Int, _ y: Int) -> Int
    public typealias Offset = @Sendable (_ frame: Int, _ n: Int) -> (dx: Int, dy: Int)

    public static let still: Multiplier = { _, _, _, _, _ in 1000 }
    public static let fixed: Offset = { _, _ in (dx: 0, dy: 0) }

    public let name: String
    public let pixels: [AnimationPixel]
    public let multiplier: Multiplier
    public let offset: Offset
    public let key: String?
    public let tint: AnimatedScene.Tint?

    public init(name: String, pixels: [AnimationPixel], multiplier: @escaping Multiplier = still,
                offset: @escaping Offset = fixed, key: String? = nil, tint: AnimatedScene.Tint? = nil) {
        self.name = name
        self.pixels = pixels
        self.multiplier = multiplier
        self.offset = offset
        self.key = key
        self.tint = tint
    }
}

/// How fast a scene plays: the same whole cycles in `den/num` times the
/// frames. The frame delay never changes.
public struct AnimationSpeed: Hashable, Sendable {
    public let num: Int
    public let den: Int
    public static let half = AnimationSpeed(num: 1, den: 2)
    public static let normal = AnimationSpeed(num: 1, den: 1)
    public static let double = AnimationSpeed(num: 2, den: 1)
    public init(num: Int, den: Int) { self.num = num; self.den = den }
    /// "1/2", "1/1", "2/1" — the oracle's spelling.
    public init?(fraction: String) {
        let parts = fraction.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        self.init(num: parts[0], den: parts[1])
    }
}

/// A full-panel animation — `nlengine.PixelScene`. No stored frames: a
/// frame is computed from its index and the loop's length, and every motion
/// is periodic in that length, so the loop has no seam at any speed.
public struct AnimatedScene: Sendable {
    public typealias Tint = @Sendable (Int) -> RGB
    public static let width = PixelCanvas.width
    public static let height = PixelCanvas.height

    public let id: String
    public let frameMs: Int
    public let cycleFrames: Int
    public let layers: [AnimationLayer]
    public let tint: Tint?

    public init(id: String, frameMs: Int, cycleFrames: Int, layers: [AnimationLayer], tint: Tint? = nil) {
        self.id = id
        self.frameMs = frameMs
        self.cycleFrames = cycleFrames
        self.layers = layers
        self.tint = tint
    }

    public func frameCount(speed: AnimationSpeed) -> Int {
        IntMath.floorDiv(cycleFrames * speed.den, speed.num)
    }

    /// One frame, row-major, nil where unlit.
    public func render(frame: Int, of n: Int, stilled: Set<String>) -> [RGB?] {
        let w = Self.width, h = Self.height
        var grid = [RGB?](repeating: nil, count: w * h)
        for layer in layers {
            let moving = layer.key.map { !stilled.contains($0) } ?? true
            let (dx, dy) = moving ? layer.offset(frame, n) : (0, 0)
            let tint = layer.tint ?? self.tint
            for (i, p) in layer.pixels.enumerated() {
                let m = moving ? layer.multiplier(frame, n, i, p.x, p.y) : 1000
                let xx = IntMath.floorMod(p.x + dx, w)
                let yy = p.y + dy
                guard 0 <= yy, yy < h else { continue }
                var out: RGB
                if let tint {
                    let r = min(255, IntMath.floorDiv(p.colour.r * m, 1000))
                    out = r != 0 ? tint(r) : .black
                    if r != 0, p.colour.g != 0 {
                        out.g = PanelLevels.amber(out.r, p.colour.g)
                    }
                } else {
                    out = RGB(r: min(255, IntMath.floorDiv(p.colour.r * m, 1000)),
                              g: min(255, IntMath.floorDiv(p.colour.g * m, 1000)),
                              b: min(255, IntMath.floorDiv(p.colour.b * m, 1000)))
                }
                if out.isLit { grid[yy * w + xx] = out }
            }
        }
        return grid
    }

    /// One frame at a brightness step, 1…5: `(ch · level + 2) / 5` per
    /// channel, and a colour scaled to nothing is unlit.
    public func canvas(frame: Int, of n: Int, stilled: Set<String>, brightness: Int) -> PixelCanvas {
        var canvas = PixelCanvas()
        for (i, cell) in render(frame: frame, of: n, stilled: stilled).enumerated() {
            guard let c = cell else { continue }
            let s = RGB(r: (c.r * brightness + 2) / 5, g: (c.g * brightness + 2) / 5, b: (c.b * brightness + 2) / 5)
            guard s.isLit else { continue }
            canvas[i % Self.width, i / Self.width] = Pixel(red: UInt8(s.r), green: UInt8(s.g), blue: UInt8(s.b))
        }
        return canvas
    }

    /// A character mask as layer pixels — `nlengine.mask`: each character
    /// names a colour, "." is empty.
    public static func mask(_ rows: [String], _ colours: [Character: RGB], x0: Int = 0, y0: Int = 0) -> [AnimationPixel] {
        rows.enumerated().flatMap { dy, row in
            row.enumerated().compactMap { dx, ch in
                ch == "." ? nil : AnimationPixel(x: x0 + dx, y: y0 + dy, colour: colours[ch]!)
            }
        }
    }
}
