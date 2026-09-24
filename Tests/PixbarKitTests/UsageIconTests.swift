import Foundation
import Testing
@testable import PixbarKit

// A vendor's mark on the matrix. The page names art by basename and the app
// uploads it to the clock's flash on demand, so art dropped from the package —
// or renamed on one side only — has to fail HERE. The device answers a missing
// icon by drawing the app with nothing beside it, which reads as an ordinary
// banner and reports nothing at all.

@Suite struct UsageIconTests {
    private static let vendors: [CodeUsage.Vendor] = [.claude, .zai]

    private func basename(_ icon: IconReference) -> String? {
        guard case let .bundled(name) = icon else { return nil }
        return name
    }

    @Test func everyVendorsMarkShipsAsEightBySixteenthsOfTheMatrix() throws {
        for vendor in Self.vendors {
            let name = try #require(
                basename(vendor.icon), "\(vendor.id) names art that is not this app's to ship"
            )
            let blob = try #require(
                BundledIcon.data(named: name),
                "\(vendor.id) names bundled art \(name) that is not in the package"
            )

            #expect(blob.starts(with: Data("GIF8".utf8)), "\(name) is not a GIF")
            // Width and height live little-endian at offsets 6 and 8. Eight by
            // eight is the whole matrix an icon gets.
            #expect(Int(blob[6]) | Int(blob[7]) << 8 == 8, "\(name) is not 8 wide")
            #expect(Int(blob[8]) | Int(blob[9]) << 8 == 8, "\(name) is not 8 tall")
        }
    }

    // The two vendors differ by their mark — so the two marks must differ.
    // Identical art would make the substrate's one page genuinely ambiguous:
    // two tiles on one clock, the same figure, nothing to tell them apart.
    @Test func theTwoVendorsDoNotShareOneMark() throws {
        let names = Self.vendors.compactMap { basename($0.icon) }

        #expect(Set(names).count == Self.vendors.count)
        let art = try names.map { try #require(BundledIcon.data(named: $0)) }
        #expect(Set(art).count == Self.vendors.count)
    }

    // z.ai's icon is DRAWN from its `logo`, so the mark has one definition.
    // The rows say where its ink is; the art must put ink in the same places.
    //
    // Read out of the GIF's own index stream rather than through an image
    // decoder: the kit has no decoder, and a two-colour 8×8 written by
    // `make_usage_icons.py` is a fixed shape — one clear code between every
    // pixel, so the codes are the pixels.
    @Test func theZaiMarkOnTheMatrixIsTheOneThePanelDraws() throws {
        let blob = try #require(BundledIcon.data(named: "ZaiZ"))
        let lit = try #require(litPixels(ofTwoColourGif: blob))
        let rows = CodeUsage.Vendor.zai.logo

        let width = rows.map(\.count).max() ?? 0
        let left = (8 - width) / 2
        let top = (8 - rows.count) / 2
        var expected: Set<Int> = []
        for (y, row) in rows.enumerated() {
            for (x, cell) in row.enumerated() where cell == "#" {
                expected.insert((top + y) * 8 + left + x)
            }
        }

        #expect(lit == expected, "the shipped mark is not the one CodeUsage.Vendor.zai draws")
    }

    /// The offsets whose pixel is the mark's colour rather than the ground.
    ///
    /// The image block's codes are read at their fixed width — `minimum + 1`
    /// bits, no dictionary growth, because the writer clears after every pixel.
    private func litPixels(ofTwoColourGif blob: Data) -> Set<Int>? {
        // Header 13 bytes, then a 2-colour global table (6 bytes), then the
        // image descriptor (10 bytes), then the LZW minimum code size.
        let start = 13 + 6 + 10
        guard blob.count > start else { return nil }
        let bytes = [UInt8](blob)
        let minimum = Int(bytes[start])
        let codeBits = minimum + 1
        let clear = 1 << minimum

        var payload: [UInt8] = []
        var cursor = start + 1
        while cursor < bytes.count, bytes[cursor] != 0 {
            let length = Int(bytes[cursor])
            guard cursor + length < bytes.count else { return nil }
            payload.append(contentsOf: bytes[(cursor + 1)...(cursor + length)])
            cursor += length + 1
        }

        var lit: Set<Int> = []
        var accumulator = 0
        var width = 0
        var pixel = 0
        for byte in payload {
            accumulator |= Int(byte) << width
            width += 8
            while width >= codeBits {
                let code = accumulator & ((1 << codeBits) - 1)
                accumulator >>= codeBits
                width -= codeBits
                if code == clear || code == clear + 1 { continue }
                if code != 0 { lit.insert(pixel) }
                pixel += 1
            }
        }
        return lit
    }
}
