// Tests/PixbarKitTests/PixelBitmapASCII.swift
import Foundation
@testable import PixbarKit

/// Renders a `db` bitmap command as golden-ASCII rows of `#`/`.`, trimmed to
/// the bounding box of its lit pixels — pins glyph geometry without pixel-
/// coordinate arithmetic. Black pixels are off; anything else is on.
func goldenASCII(of draw: UlanziDraw) -> [String] {
    guard case let .bitmap(width, _, pixels, _) = draw else { return [] }
    let lit = pixels.enumerated().filter { $0.element != 0 }
    guard let first = lit.first else { return [] }
    let xs = lit.map { $0.offset % width }
    let ys = lit.map { $0.offset / width }
    let left = xs.min()!, right = xs.max()!, top = ys.min()!, bottom = ys.max()!
    _ = first
    let litSet = Set(lit.map(\.offset))
    return (top...bottom).map { y in
        String((left...right).map { x in
            litSet.contains(y * width + x) ? "#" : "."
        })
    }
}

/// The packed RGB of one pixel of a `db` command, 0x00RRGGBB.
func pixelValue(of draw: UlanziDraw, x: Int, y: Int, width: Int) -> UInt32 {
    guard case let .bitmap(_, _, pixels, _) = draw else { return 0 }
    return pixels[y * width + x]
}
