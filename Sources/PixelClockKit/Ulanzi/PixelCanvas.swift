import Foundation

/// One 8-bit RGB pixel, packed for the TC002 panel.
public struct Pixel: Sendable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public static let black = Pixel(red: 0, green: 0, blue: 0)
    public static let white = Pixel(red: 255, green: 255, blue: 255)

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct PixelPoint: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int

    public static let zero = PixelPoint(x: 0, y: 0)

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct PixelRect: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A 52×16 RGB raster — the exact frame the TC002 panel shows.
///
/// Faces render here and the canvas leaves as one `db` bitmap command (see
/// `drawCommands`). Row-major, origin at the top-left corner.
///
/// Out-of-range subscripts are a precondition failure — a programmer error,
/// never a silent clip. The draw primitives clip instead, because a face
/// drawing to the edge of the panel is ordinary and drawing past it is a bug
/// worth surviving.
public struct PixelCanvas: Sendable, Equatable {
    public static let width = 52
    public static let height = 16

    private var pixels: [Pixel]

    public init() {
        pixels = .init(repeating: .black, count: Self.width * Self.height)
    }

    public subscript(x: Int, y: Int) -> Pixel {
        get {
            Self.preconditionBounds(x: x, y: y)
            return pixels[y * Self.width + x]
        }
        set {
            Self.preconditionBounds(x: x, y: y)
            pixels[y * Self.width + x] = newValue
        }
    }

    private static func preconditionBounds(x: Int, y: Int) {
        precondition(
            x >= 0 && x < width && y >= 0 && y < height,
            "pixel (\(x), \(y)) is outside the \(width)×\(height) panel"
        )
    }

    /// Bounds-checked write for the clipping primitives. Paints nothing outside
    /// the panel rather than crashing: clipping is their contract.
    private mutating func paint(_ x: Int, _ y: Int, _ color: Pixel) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        self[x, y] = color
    }

    public mutating func fill(_ color: Pixel) {
        pixels = .init(repeating: color, count: Self.width * Self.height)
    }

    /// The filled rectangle, clipped to the panel — everything of the rect the
    /// panel can actually show gets painted, and the rest is dropped.
    public mutating func drawRect(_ rect: PixelRect, color: Pixel) {
        guard rect.width > 0, rect.height > 0 else { return }
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                paint(x, y, color)
            }
        }
    }

    /// Bresenham's line, clipped to the panel.
    public mutating func drawLine(from: PixelPoint, to: PixelPoint, color: Pixel) {
        var x0 = from.x, y0 = from.y
        let x1 = to.x, y1 = to.y
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var error = dx + dy
        while true {
            paint(x0, y0, color)
            if x0 == x1, y0 == y1 { break }
            let doubled = 2 * error
            if doubled >= dy { error += dy; x0 += sx }
            if doubled <= dx { error += dx; y0 += sy }
        }
    }

    /// Walks `PixelFont.glyph(for:)` per character — 4-column advance at scale
    /// 1 (3 glyph columns + 1 gap), painting `ink` where a glyph bit is set.
    /// A character outside the font's set is skipped but still advances, so a
    /// stray glyph costs a gap rather than shifting everything after it.
    public mutating func drawText(
        _ text: String, at origin: PixelPoint, ink: Pixel, scale: Int = 1
    ) {
        var cursor = origin.x
        for character in text {
            if let glyph = PixelFont.glyph(for: character) {
                for (row, bits) in glyph.enumerated() {
                    for column in 0..<3 where bits & (1 << column) != 0 {
                        for dy in 0..<scale {
                            for dx in 0..<scale {
                                paint(
                                    cursor + column * scale + dx,
                                    origin.y + row * scale + dy,
                                    ink
                                )
                            }
                        }
                    }
                }
            }
            cursor += 4 * scale
        }
    }
}
