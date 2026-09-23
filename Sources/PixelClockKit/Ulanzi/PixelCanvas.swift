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

/// A raster in the clock's own pixels — by default the exact frame the TC002
/// panel shows.
///
/// Faces render here and the canvas leaves as one `db` bitmap command (see
/// `drawCommands`). Row-major, origin at the top-left corner.
///
/// The dimensions are the canvas's own, not a constant of the type: the
/// preview renders a tile's face for the model it sits on, and an AWTRIX
/// panel is 32×16 where the TC002 is 52×16. The static `width`/`height`
/// remain, spelling the TC002 panel — the faces that draw full-screen read
/// them — while a canvas built `init(width:height:)` answers its own.
///
/// Out-of-range subscripts are a precondition failure — a programmer error,
/// never a silent clip. The draw primitives clip instead, because a face
/// drawing to the edge of the panel is ordinary and drawing past it is a bug
/// worth surviving.
public struct PixelCanvas: Sendable, Equatable {
    /// The TC002 panel's size — the default canvas, and what every full-screen
    /// TC002 face reads.
    public static let width = 52
    public static let height = 16

    public let width: Int
    public let height: Int

    private var pixels: [Pixel]

    public init() {
        width = Self.width
        height = Self.height
        pixels = .init(repeating: .black, count: width * height)
    }

    /// A canvas of another panel's geometry — the AWTRIX preview's 32×16, for
    /// one. Dimensions below one are refused: a panel with no pixels is not a
    /// panel.
    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "a panel with no pixels is not a panel")
        self.width = width
        self.height = height
        pixels = .init(repeating: .black, count: width * height)
    }

    public subscript(x: Int, y: Int) -> Pixel {
        get {
            Self.preconditionBounds(x: x, y: y, width: width, height: height)
            return pixels[y * width + x]
        }
        set {
            Self.preconditionBounds(x: x, y: y, width: width, height: height)
            pixels[y * width + x] = newValue
        }
    }

    private static func preconditionBounds(x: Int, y: Int, width: Int, height: Int) {
        precondition(
            x >= 0 && x < width && y >= 0 && y < height,
            "pixel (\(x), \(y)) is outside the \(width)×\(height) panel"
        )
    }

    /// Bounds-checked write for the clipping primitives. Paints nothing outside
    /// the panel rather than crashing: clipping is their contract.
    private mutating func paint(_ x: Int, _ y: Int, _ color: Pixel) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        self[x, y] = color
    }

    public mutating func fill(_ color: Pixel) {
        pixels = .init(repeating: color, count: width * height)
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

    /// The filled circle, clipped to the panel: every pixel whose centre lies
    /// within `radius` of the circle's own.
    public mutating func drawFilledCircle(center: PixelPoint, radius: Int, color: Pixel) {
        guard radius >= 0 else { return }
        for y in (center.y - radius)...(center.y + radius) {
            for x in (center.x - radius)...(center.x + radius)
            where (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y) <= radius * radius {
                paint(x, y, color)
            }
        }
    }

    /// The circle's outline: the four axis points and the ring between them,
    /// the centre left unpainted — a filled circle's test knows the difference.
    public mutating func drawCircle(center: PixelPoint, radius: Int, color: Pixel) {
        guard radius > 0 else {
            if radius == 0 { paint(center.x, center.y, color) }
            return
        }
        // Midpoint circle: one octant computed, eight places mirrored, the
        // decision step walked with integers only.
        var x = 0
        var y = radius
        var error = 1 - radius
        while x <= y {
            paint(center.x + x, center.y + y, color)
            paint(center.x - x, center.y + y, color)
            paint(center.x + x, center.y - y, color)
            paint(center.x - x, center.y - y, color)
            paint(center.x + y, center.y + x, color)
            paint(center.x - y, center.y + x, color)
            paint(center.x + y, center.y - x, color)
            paint(center.x - y, center.y - x, color)
            if error < 0 {
                error += 2 * x + 3
            } else {
                error += 2 * (x - y) + 5
                y -= 1
            }
            x += 1
        }
    }

    /// Walks the face per character, painting `ink` where a glyph bit is set
    /// and stepping one advance — the cell plus its gap — between them.
    ///
    /// The face is a parameter because the kit draws in two of them: the 3×5
    /// cell the three-band usage page is built around, and the X11 5×7 face
    /// with the Cyrillic alphabet. It defaults to the small one, so every face
    /// written before the second one existed draws exactly where it did.
    ///
    /// A mark the face has no shape for draws the SUBSTITUTE rather than
    /// nothing. Skipping it was the old behaviour and it is what made the
    /// panel lie: the cursor advanced over a blank cell, so an unspellable
    /// letter read as a space in the middle of a word instead of as a
    /// character the font could not draw.
    public mutating func drawText(
        _ text: String, at origin: PixelPoint, ink: Pixel, scale: Int = 1,
        font: PixelFontFace = PixelFont.tiny
    ) {
        var cursor = origin.x
        for character in text {
            if let glyph = font.glyph(for: character) {
                for (row, bits) in glyph.enumerated() {
                    for column in 0..<font.columns(of: character) where bits & (1 << column) != 0 {
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
            cursor += font.advance(for: character) * scale
        }
    }

    /// Another raster laid on this one at `origin`, clipped to the panel.
    ///
    /// The primitive a composed face needs: text that must not spill into the
    /// columns an icon owns is drawn on a strip of its own and blitted here,
    /// so the clip is the STRIP's width rather than the panel's. Doing it by
    /// hand at each call site is how two faces end up clipping differently.
    public mutating func draw(_ other: PixelCanvas, at origin: PixelPoint) {
        for y in 0..<other.height {
            for x in 0..<other.width {
                paint(origin.x + x, origin.y + y, other[x, y])
            }
        }
    }

    /// The device's draw vocabulary, painted onto this raster — how a scene's
    /// own commands become the preview's pixels. Text draws through the
    /// canvas's font at the command's height (`large` at the double scale),
    /// which is the preview's one approximation: the device sets its own
    /// glyphs, and the words land where its would.
    public mutating func apply(_ commands: [UlanziDraw]) {
        for command in commands {
            apply(command)
        }
    }

    public mutating func apply(_ command: UlanziDraw) {
        switch command {
        case let .pixel(point, colour):
            paint(point.x, point.y, Pixel(colour: colour))
        case let .line(from, to, colour):
            drawLine(from: from, to: to, color: Pixel(colour: colour))
        case let .rect(x, y, rectWidth, rectHeight, colour):
            let ink = Pixel(colour: colour)
            drawRect(PixelRect(x: x, y: y, width: rectWidth, height: 1), color: ink)
            drawRect(PixelRect(x: x, y: y + rectHeight - 1, width: rectWidth, height: 1), color: ink)
            drawRect(PixelRect(x: x, y: y, width: 1, height: rectHeight), color: ink)
            drawRect(PixelRect(x: x + rectWidth - 1, y: y, width: 1, height: rectHeight), color: ink)
        case let .filledRect(x, y, rectWidth, rectHeight, colour):
            drawRect(PixelRect(x: x, y: y, width: rectWidth, height: rectHeight), color: Pixel(colour: colour))
        case let .circle(center, radius, colour):
            drawCircle(center: center, radius: radius, color: Pixel(colour: colour))
        case let .filledCircle(center, radius, colour):
            drawFilledCircle(center: center, radius: radius, color: Pixel(colour: colour))
        case let .text(content, at, colour, font):
            drawText(
                content,
                at: at,
                ink: Pixel(colour: colour),
                scale: font == .large ? 2 : 1
            )
        case let .bitmap(bitmapWidth, bitmapHeight, packed, at):
            guard packed.count == bitmapWidth * bitmapHeight else { return }
            for row in 0..<bitmapHeight {
                for column in 0..<bitmapWidth {
                    let value = packed[row * bitmapWidth + column]
                    paint(
                        at.x + column,
                        at.y + row,
                        Pixel(
                            red: UInt8((value >> 16) & 0xFF),
                            green: UInt8((value >> 8) & 0xFF),
                            blue: UInt8(value & 0xFF)
                        )
                    )
                }
            }
        }
    }

    /// The whole canvas as one full-screen db command — how every face ships
    /// (D2). Pixels packed 0x00RRGGBB, row-major from the top-left corner.
    public func drawCommands() -> UlanziDraw {
        var packed: [UInt32] = []
        packed.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = self[x, y]
                packed.append(UInt32(p.red) << 16 | UInt32(p.green) << 8 | UInt32(p.blue))
            }
        }
        return .bitmap(width: width, height: height, pixels: packed, at: .zero)
    }
}
