import Foundation

/// The animation engine's arithmetic, integer only and spelled like Python's,
/// so a scene renders here exactly as the mockup's `nlengine.py` rendered it.
///
/// Python's `//` and `%` floor; Swift's `/` and `%` truncate. The two agree
/// only for non-negative operands, and a scene divides sines, drifts and
/// jitters that are signed — so every division a scene ports is one of these.
public enum IntMath {
    /// `round(127·sin(2πi/256))`, pinned by the fixture.
    public static let sin: [Int] = (0..<256).map { Int((127 * Foundation.sin(2 * Double.pi * Double($0) / 256)).rounded()) }

    /// Python's `a // b`.
    public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Python's `a % b`: the sign of the divisor.
    public static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }

    /// `nlengine.sdiv`: division truncating toward zero.
    public static func truncDiv(_ a: Int, _ b: Int) -> Int { a / b }

    /// Python's `math.isqrt`: the floor of the square root.
    public static func isqrt(_ n: Int) -> Int {
        precondition(n >= 0, "isqrt of a negative number")
        if n < 2 { return n }
        var x = n
        var y = (x + 1) / 2
        while y < x {
            x = y
            y = (x + n / x) / 2
        }
        return x
    }

    /// A fixed pseudo-random −spread … +spread per pixel — the scenes'
    /// `jitter`, a spatial hash on 32 bits. The product runs in `UInt64` with
    /// wrapping: 32 bits times 2654435761 overflows `Int`.
    public static func jitter(_ x: Int, _ y: Int, _ spread: Int) -> Int {
        var h = UInt64(bitPattern: Int64((x * 73_856_093) ^ (y * 19_349_663) ^ 0x5BD1_E995)) & 0xFFFF_FFFF
        h = ((h &* 2_654_435_761) & 0xFFFF_FFFF) >> 16
        return floorDiv(Int(h) * 2 * spread, 0xFFFF) - spread
    }

    /// The SIN index at `cycles` whole turns per loop of `n` frames.
    public static func phase(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int = 0) -> Int {
        (floorDiv(frame * cycles * 256, n) + offset) & 255
    }

    /// `low + (high − low)·(½ + ½·sin)`, per mille.
    public static func swing(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int, _ low: Int, _ high: Int) -> Int {
        let s = sin[phase(frame, n, cycles, offset)]
        return low + floorDiv((high - low) * (s + 127), 254)
    }

    /// A triangle from `low` to `high` and back, per mille.
    public static func ramp(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int, _ low: Int, _ high: Int) -> Int {
        let p = phase(frame, n, cycles, offset)
        let t = p < 128 ? p : 256 - p
        return low + floorDiv((high - low) * t, 128)
    }
}
