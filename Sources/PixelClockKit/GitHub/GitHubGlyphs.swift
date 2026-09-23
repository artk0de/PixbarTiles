import Foundation

// The GitHub face's 16×16 icons: GitHub's own octicons as per-pixel coverage,
// quantised for LEDs, and the loops they play — ports of `ggen.py`'s
// `coverage`, `sample`, `glyph`, `lit`, `octocat`, `star_icon`, `pulse`,
// `fork_icon`, `pr_icon` and `ci_icon`, in that order. Every constant and every float
// expression is ggen's, because the oracle holds these pixels to it.

extension GitHubFace {
    // MARK: - The octicons

    /// `github/octicons.py`'s `OCTICONS`, byte for byte (primer/octicons,
    /// MIT): each SVG rendered at 160 px, box-averaged to 16×16, alpha kept as
    /// one byte per pixel — 32 hex digits a row, `00` empty, `ff` covered.
    /// `GitHubFaceOracleTests` holds this literal to the recorded table;
    /// re-run the skill's `make_octicons.py`, then the oracle, never edit here.
    static let octicons: [String: [String]] = [
        "mark": [
            "000000003198dafaf9d9962f00000000", "0000099afefffffffffffffd97080000",
            "0009c0ffffffffffffffffffffbe0800", "0098fff974c5f9ddddf8c373faff9600",
            "2ffeffe00001080000060100e3fffd2e", "96ffffdf0000000000000000e2ffff95",
            "d8ffff76000000000000000075ffffd8", "f9ffff44000000000000000044fffff9",
            "faffff5c00000000000000005cfffff9", "dbffffc30200000000000003c4ffffda",
            "99fffdffa5110000000015a9ffffff99", "33fe9643f8f45600005ef7fffffffe34",
            "009cff523f5f0100000cfaffffff9e00", "0009c1ea583b00000000e8ffffc50b00",
            "00000996fdff00000000e7fe9e0b0000", "000000002b67000000005f3200000000",
        ],
        "star": [
            "00000000000000727300000000000000", "0000000000001cf8f81c000000000000",
            "00000000000093ffff93000000000000", "00000000001af7fffff71a0000000000",
            "0000163b60b6ffffffffb6623c170000", "42f0ffffffffffffffffffffffffef41",
            "21e4ffffffffffffffffffffffffe521", "0024e1ffffffffffffffffffffe22400",
            "000020deffffffffffffffffdf210000", "0000003bffffffffffffffff3b000000",
            "00000055ffffffffffffffff55000000", "00000081ffffffffffffffff81000000",
            "000000acfffffb9c9bfbffffac000000", "000000d2fea927000026a8fed2000000",
            "0000003d30000000000000303d000000", "00000000000000000000000000000000",
        ],
        "fork": [
            "00000000000000000000000000000000", "000037d8f6950300000395f6d8370000",
            "0000d8dd9fff58000059ff9fddd80000", "0000f69f22ff77000077ff229ff60000",
            "000095fffff123000023f2ffff950000", "000003a0ff240000000023ffa0030000",
            "00000077ff1f0000000020ff77000000", "00000023f1fffffffffffff123000000",
            "00000000237780dfdf80772300000000", "00000000000000bfbf00000000000000",
            "0000000000000fd4d40f000000000000", "000000000005d1ffffd1050000000000",
            "000000000037ff6060ff370000000000", "00000000001dfcbebefc1d0000000000",
            "00000000000064eceb64000000000000", "00000000000000000000000000000000",
        ],
        "pr": [
            "00000000000000000034000000000000", "000395f6d837000048f7000000000000",
            "0059ff9fddd80048f7ff806e14000000", "0076ff229ff600acffffffffe2140000",
            "0023f1ffff950008b7ff0038ff6e0000", "000023ffa003000008ab0000ff800000",
            "000000ff8000000000000000ff800000", "000000ff8000000000000000ff800000",
            "000000ff8000000000000000ff800000", "000000ff8000000000000000ff800000",
            "000024ffa103000000000024ffa10300", "0024f2ffff960000000024f2ffff9600",
            "0077ff219ff60000000077ff219ff600", "0059ff9fddd80000000059ff9fddd800",
            "000396f7d838000000000396f7d83800", "00000000000000000000000000000000",
        ],
        "ci": [
            "000000003198dafafad9983100000000", "0000099afefffffffffffffe9b090000",
            "0009c1ffffffffffffffffffffc20900", "009affffffffffffffffffffffff9b00",
            "31feffffffd4ffffffffcbfefffffe31", "98ffffffd40071ffff7100cbffffff97",
            "d9ffffffff710070710071ffffffffd9", "faffffffffff71000071fffffffffff9",
            "faffffffffff71000070fefffffffff9", "d9ffffffff710071710070ffffffffd9",
            "97ffffffcb0071ffff7100cbffffff97", "31fefffffecbffffffffcbfefffffe31",
            "009affffffffffffffffffffffff9a00", "0009c1ffffffffffffffffffffc20900",
            "0000099afefffffffffffffe9a090000", "000000003197d9f9f9d9973100000000",
        ],
    ]

    // MARK: - Quantising for LEDs

    /// Coverage at or above `full` is a lit pixel, at or above `edge` a dimmed
    /// edge in the icon's colour at `edgeTint`, below it nothing.
    static let full = 0.6, edge = 0.25, edgeTint = 0.45

    static func tint(_ ink: Pixel, _ k: Double) -> Pixel {
        func scaled(_ v: UInt8) -> UInt8 { UInt8(WeatherFace.halfEven(Double(v) * k)) }
        return Pixel(red: scaled(ink.red), green: scaled(ink.green), blue: scaled(ink.blue))
    }

    /// An octicon's coverage, 0–1, `[y][x]`.
    static func coverage(_ key: String) -> [[Double]] {
        octicons[key]!.map { row in
            let digits = Array(row)
            return (0..<16).map { x in Double(Int(String(digits[2 * x..<2 * x + 2]), radix: 16)!) / 255 }
        }
    }

    /// Bilinear coverage at a fractional position, 0 outside — ggen's float
    /// expression, term for term, so a boundary pixel lands where Python's does.
    static func sample(_ coverage: [[Double]], _ x: Double, _ y: Double) -> Double {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        func at(_ i: Int, _ j: Int) -> Double {
            (0..<16).contains(i) && (0..<16).contains(j) ? coverage[j][i] : 0.0
        }
        return at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy)
            + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy
    }

    /// An octicon quantised for LEDs; `scale` draws it about the centre (the
    /// star's pop-in).
    static func glyph(_ key: String, _ ink: Pixel, scale: Double = 1.0) -> PixelCanvas {
        let cov = coverage(key)
        var canvas = PixelCanvas(width: 16, height: 16)
        for y in 0..<16 {
            for x in 0..<16 {
                let a = scale == 1.0
                    ? cov[y][x]
                    : sample(cov, (Double(x) - 7.5) / scale + 7.5, (Double(y) - 7.5) / scale + 7.5)
                if a >= full {
                    canvas[x, y] = ink
                } else if a >= edge {
                    canvas[x, y] = tint(ink, edgeTint)
                }
            }
        }
        return canvas
    }

    /// The fully lit pixels of an octicon.
    static func lit(_ key: String) -> [PixelPoint] {
        coverage(key).enumerated().flatMap { y, row in
            row.enumerated().compactMap { x, a in a >= full ? PixelPoint(x: x, y: y) : nil }
        }
    }

    // MARK: - The loops

    /// GitHub's mark in a steady grey with a diagonal shine sweeping across it
    /// every 2.4 s. Dimmed and still when the tile has nothing to show.
    static func octocat(dim: Bool = false) -> [WeatherFace.Cel] {
        let still = glyph("mark", dim ? WeatherFace.dim : markInk)
        if dim { return [(still, 1000)] }
        let body = lit("mark")
        var frames: [WeatherFace.Cel] = [(still, 2400)]
        for k in stride(from: -2, to: 34, by: 2) {
            var frame = still
            for point in body {
                let d = abs(point.x + point.y - k)
                if d <= 1 { frame[point.x, point.y] = d == 0 ? shineInk : whiteInk }
            }
            frames.append((frame, 60))
        }
        return frames
    }

    /// The empty corners the star's sparks blink in, in turn.
    static let sparks = [(1, 2), (14, 1), (0, 12), (15, 12), (2, 15), (13, 15)]

    /// Pops in (small → overshoot → settle), then twinkles for as long as the
    /// celebration lasts.
    static func starIcon() -> (pop: [WeatherFace.Cel], loop: [WeatherFace.Cel]) {
        let pop = [0.3, 0.55, 0.8, 1.12, 1.0].map { (glyph("star", starInk, scale: $0), 70) }
        let base = glyph("star", starInk)
        let loop = sparks.map { x, y -> WeatherFace.Cel in
            var frame = base
            if frame[x, y] == .black { frame[x, y] = shineInk }
            return (frame, 240)
        }
        return (pop, loop)
    }

    /// The octicon lit steadily, with a bright band travelling across its lit
    /// pixels in `order` — a commit running along the branch — then a rest.
    static func pulse(_ key: String, _ ink: Pixel, order: (PixelPoint) -> Int) -> [WeatherFace.Cel] {
        let base = glyph(key, ink)
        let body = lit(key)
        let steps = Set(body.map(order)).sorted()
        var frames: [WeatherFace.Cel] = steps.map { step in
            var frame = base
            for point in body where order(point) == step {
                frame[point.x, point.y] = shineInk
            }
            return (frame, 70)
        }
        frames.append((base, 700))
        return frames
    }

    /// A commit runs down from the two tips to the base.
    static func forkIcon() -> [WeatherFace.Cel] {
        pulse("fork", forkInk) { $0.y }
    }

    /// A commit runs up the incoming branch and across the arrow into the base.
    static func prIcon() -> [WeatherFace.Cel] {
        pulse("pr", prInk) { $0.x >= 8 ? 15 - $0.y : 99 }
    }

    /// GitHub's failed-check glyph in red; the disc brightens and settles in
    /// turn for as long as the event lasts.
    static func ciIcon() -> [WeatherFace.Cel] {
        let cov = coverage("ci")
        func disc(_ ink: Pixel) -> PixelCanvas {
            // The cross is holes in the disc; at LED scale holes read as a
            // plain disc, so the holes inside it are lit white.
            var canvas = glyph("ci", ink)
            for y in 0..<16 {
                for x in 0..<16 {
                    let dx = Double(x) - 7.5, dy = Double(y) - 7.5
                    if cov[y][x] < edge, dx * dx + dy * dy <= 36 {
                        canvas[x, y] = whiteInk
                    }
                }
            }
            return canvas
        }
        return [(disc(ciFailInk), 400), (disc(WeatherFace.rgb(0xFF_9A_92)), 400)]
    }
}
