import Foundation
@testable import PixbarKit

/// `Scripts/make_animation_oracle.py`'s fixture: the approved scenes' frames
/// as the mockup computed them.
struct AnimationOracle: Decodable {
    struct Missing: Error { let what: String }

    struct Scene: Decodable {
        let frameMs: Int
        let cycleFrames: Int
        let toggles: [String]
        let palette: [String]
        let framesZ: String

        /// The default variant's frames, nil for unlit.
        func frames() throws -> [[RGB?]] {
            let colours = palette.map { hex -> RGB in
                let v = Int(hex, radix: 16)!
                return RGB(r: v >> 16, g: (v >> 8) & 255, b: v & 255)
            }
            guard let compressed = Data(base64Encoded: framesZ) else { throw Missing(what: "framesZ") }
            let json = try (compressed as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode([String].self, from: json).map { row in
                let bytes = Array(row.utf8)
                return stride(from: 0, to: bytes.count, by: 2).map { i in
                    let index = Int(String(decoding: bytes[i..<i + 2], as: UTF8.self), radix: 16)!
                    return index == 0 ? nil : colours[index]
                }
            }
        }
    }

    struct Variant: Decodable {
        let scene: String
        let speed: String
        let stilled: [String]
        let brightness: Int
        let frames: Int
        let fnv: String
    }

    let scenes: [String: Scene]
    let variants: [Variant]

    static func load() throws -> AnimationOracle {
        guard let url = Bundle.module.url(forResource: "animation_oracle", withExtension: "json") else {
            throw Missing(what: "animation_oracle.json")
        }
        return try JSONDecoder().decode(AnimationOracle.self, from: Data(contentsOf: url))
    }

    /// FNV-1a-64 over every frame's RGB bytes, row-major — the recorder's `fnv`.
    static func fnv(_ canvases: [PixelCanvas]) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for canvas in canvases {
            for y in 0..<canvas.height {
                for x in 0..<canvas.width {
                    let p = canvas[x, y]
                    for b in [p.red, p.green, p.blue] {
                        h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3
                    }
                }
            }
        }
        return String(format: "%016llx", h)
    }
}
