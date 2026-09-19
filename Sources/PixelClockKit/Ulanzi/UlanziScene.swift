import Foundation

/// A colour for `draw` commands, packed 0x00RRGGBB as the device expects.
public struct UlanziColour: Sendable, Equatable, Hashable {
    public let value: UInt32

    public static let black = UlanziColour(value: 0)
    public static let white = UlanziColour(value: 0xFF_FF_FF)

    public init(value: UInt32) {
        self.value = value
    }

    /// Parses the `#RRGGBB` form the kit already produces colours in
    /// (`TemperatureColour.hex`, `ClaudeUsage.brandColour`). Own output only —
    /// the parser trusts the six hex digits and never meets anything else.
    public init(hex: String) {
        let digits = hex.dropFirst(hex.hasPrefix("#") ? 1 : 0)
        self.value = UInt32(digits, radix: 16) ?? 0
    }
}

extension Pixel {
    /// The canvas draws in the same colours the scene vocabulary names.
    public init(colour: UlanziColour) {
        self.init(
            red: UInt8((colour.value >> 16) & 0xFF),
            green: UInt8((colour.value >> 8) & 0xFF),
            blue: UInt8(colour.value & 0xFF)
        )
    }
}

public enum UlanziFontHeight: Int, Sendable, Equatable {
    case small = 5
    case large = 10
}

/// One `draw[]` command in the device vocabulary (research §2.2).
///
/// Phase-3 faces ship exactly one command, the full-screen `db` bitmap (D2);
/// the rest of the grammar is here so the vocabulary is complete. Every case
/// encodes as `{ "<device key>": [args in declaration order] }`.
public enum UlanziDraw: Sendable, Equatable {
    case pixel(PixelPoint, UlanziColour)                            // dp
    case line(PixelPoint, PixelPoint, UlanziColour)                 // dl
    case rect(x: Int, y: Int, w: Int, h: Int, UlanziColour)         // dr
    case filledRect(x: Int, y: Int, w: Int, h: Int, UlanziColour)   // df
    case circle(center: PixelPoint, radius: Int, UlanziColour)      // dc
    case filledCircle(center: PixelPoint, radius: Int, UlanziColour) // dfc
    case text(String, at: PixelPoint, color: UlanziColour, font: UlanziFontHeight) // dt
    /// `[width, height, width*height packed pixels]` — what PixelCanvas ships as.
    case bitmap(width: Int, height: Int, pixels: [UInt32], at: PixelPoint)   // db

    var jsonObject: [String: Any] {
        let int = { (point: PixelPoint) -> [Int] in [point.x, point.y] }
        let colour = { (c: UlanziColour) -> Int in Int(c.value) }
        switch self {
        case let .pixel(point, c):
            return ["dp": int(point) + [colour(c)]]
        case let .line(from, to, c):
            return ["dl": int(from) + int(to) + [colour(c)]]
        case let .rect(x, y, w, h, c):
            return ["dr": [x, y, w, h, colour(c)]]
        case let .filledRect(x, y, w, h, c):
            return ["df": [x, y, w, h, colour(c)]]
        case let .circle(center, radius, c):
            return ["dc": int(center) + [radius, colour(c)]]
        case let .filledCircle(center, radius, c):
            return ["dfc": int(center) + [radius, colour(c)]]
        case let .text(content, at, c, font):
            return ["dt": int(at) + [colour(c), font.rawValue] + [content]]
        case let .bitmap(width, height, pixels, _):
            // The phase ships only the full-screen bitmap at the origin, and
            // that is the one spelling pinned against a real exchange. When a
            // positioned bitmap ever ships, its first send test pins the
            // position spelling the same way.
            return ["db": [width, height] + pixels.map { Int($0) }]
        }
    }
}

/// One `image[]` entry. Declared metadata — the encoder validates against the
/// measured limits (D7); the device enforces reality.
public struct UlanziImage: Sendable, Equatable {
    public let base64: String
    public let isAnimated: Bool
    public let frameCount: Int
    public let pixelSize: (width: Int, height: Int)

    public init(
        base64: String, isAnimated: Bool, frameCount: Int, pixelSize: (width: Int, height: Int)
    ) {
        self.base64 = base64
        self.isAnimated = isAnimated
        self.frameCount = frameCount
        self.pixelSize = pixelSize
    }

    /// Hand-written: the tuple stored property keeps Equatable from being
    /// synthesized for the struct.
    public static func == (lhs: UlanziImage, rhs: UlanziImage) -> Bool {
        lhs.base64 == rhs.base64
            && lhs.isAnimated == rhs.isAnimated
            && lhs.frameCount == rhs.frameCount
            && lhs.pixelSize.width == rhs.pixelSize.width
            && lhs.pixelSize.height == rhs.pixelSize.height
    }

    var jsonObject: Any {
        // The bare base64 payload — the one part the device cannot do without.
        // The element spelling around it (durations, frame counts) is the one
        // wire detail no phase-3 capture pins; a face shipping a positioned or
        // timed image pins it against a real exchange first.
        base64
    }
}

public struct UlanziText: Sendable, Equatable {
    public var content: String

    public init(content: String) {
        self.content = content
    }
}

public struct UlanziFrame: Sendable, Equatable {
    public var duration: Int
    public var draw: [UlanziDraw]
    public var image: [UlanziImage]
    public var text: [UlanziText]

    public init(
        duration: Int, draw: [UlanziDraw] = [], image: [UlanziImage] = [], text: [UlanziText] = []
    ) {
        self.duration = duration
        self.draw = draw
        self.image = image
        self.text = text
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["duration": duration]
        if !draw.isEmpty { object["draw"] = draw.map(\.jsonObject) }
        if !image.isEmpty { object["image"] = image.map(\.jsonObject) }
        if !text.isEmpty { object["text"] = text.map(\.content) }
        return object
    }
}

public struct UlanziScene: Sendable, Equatable {
    /// Measured ceilings (research §4 / D7). Constants rather than literals in
    /// the checks, so each one has exactly one home — and each is pinned by its
    /// own boundary test, one over throwing, at-limit passing.
    static let maxDrawCommands = 32
    static let maxImages = 6
    static let maxAnimatedImages = 3
    static let maxAnimatedSide = 256
    static let maxAnimatedFrames = 50
    static let maxStillSide = 512
    static let maxBase64Bytes = 60_000

    public var frames: [UlanziFrame]

    public init(frames: [UlanziFrame]) {
        self.frames = frames
    }

    /// The paused-tile presence frame: one dim dot (D4). A single command, so
    /// the idle page costs the device nothing and reads as "nothing to say".
    public static let idle = UlanziScene(
        frames: [
            UlanziFrame(
                duration: 5,
                draw: [
                    .filledCircle(
                        center: PixelPoint(x: 2, y: 13), radius: 1, UlanziColour(value: 0x20_20_20)
                    )
                ]
            )
        ]
    )

    /// The payload `POST /api/custom` carries. Single frame only (A7: the
    /// carousel never cycles custom apps, so extra frames would silently never
    /// show), and every measured limit is enforced here rather than trusted to
    /// the device.
    public func jsonObject() throws -> [String: Any] {
        guard frames.count == 1 else {
            throw UlanziError.limit("a TC002 scene is exactly one frame, got \(frames.count)")
        }
        let frame = frames[0]
        guard frame.draw.count <= Self.maxDrawCommands else {
            throw UlanziError.limit("at most \(Self.maxDrawCommands) draw commands, got \(frame.draw.count)")
        }
        guard frame.image.count <= Self.maxImages else {
            throw UlanziError.limit("at most \(Self.maxImages) images, got \(frame.image.count)")
        }
        let animated = frame.image.filter(\.isAnimated)
        guard animated.count <= Self.maxAnimatedImages else {
            throw UlanziError.limit("at most \(Self.maxAnimatedImages) animated images, got \(animated.count)")
        }
        for image in frame.image {
            let side = Self.maxAnimatedSide, frames = Self.maxAnimatedFrames
            let still = Self.maxStillSide, bytes = Self.maxBase64Bytes
            if image.isAnimated {
                guard image.pixelSize.width <= side, image.pixelSize.height <= side else {
                    throw UlanziError.limit(
                        "animated image at most \(side)×\(side), got \(image.pixelSize.width)×\(image.pixelSize.height)"
                    )
                }
                guard image.frameCount <= frames else {
                    throw UlanziError.limit(
                        "animated image at most \(frames) frames, got \(image.frameCount)"
                    )
                }
            } else {
                guard image.pixelSize.width <= still, image.pixelSize.height <= still else {
                    throw UlanziError.limit(
                        "still image at most \(still)×\(still), got \(image.pixelSize.width)×\(image.pixelSize.height)"
                    )
                }
            }
            guard image.base64.utf8.count <= bytes else {
                throw UlanziError.limit(
                    "image base64 at most \(bytes) bytes, got \(image.base64.utf8.count)"
                )
            }
        }
        var object = frame.jsonObject
        if let text = object["text"] as? [String] {
            object["text"] = text.map(Self.printableASCII)
        }
        return object
    }

    /// Characters outside 0x20–0x7E are dropped. Anything substituted back has
    /// to be printable ASCII itself, and a mark nobody's glyph table covers
    /// says nothing a gap does not say more honestly.
    private static func printableASCII(_ text: String) -> String {
        String(text.filter { character in
            character.asciiValue.map { (0x20...0x7E).contains($0) } == true
        })
    }
}
