import Foundation

// The weather face's 16x16 animations — a function-for-function port of the
// `tc002-face-mockup` skill's `weather/icons.py` (plus `wgen.nodata_icon`).
// That Python is the approved design, and `WeatherIconTests` holds this file
// to its recorded frames pixel for pixel and delay for delay. Change the
// Python and re-record the oracle; never adjust the art here by hand.
//
// The port keeps the Python's names and its arithmetic exactly:
// - `round()` is Python 3's round-half-to-even → `pyRound`;
// - `%` and `//` floor on negatives → `floorMod` / `floorDiv`;
// - `a ** 2` on floats is libm `pow`, kept as `pow` so the last bit agrees;
// - expressions keep Python's evaluation order, and writes keep its order,
//   because a later `put` overwrites an earlier one.

// MARK: - Python arithmetic

/// Python 3 `round(x)`: nearest integer, ties to even.
@inline(__always) private func pyRound(_ value: Double) -> Int {
    Int(value.rounded(.toNearestOrEven))
}

/// Python `a % b` for ints: the result takes the sign of `b`.
@inline(__always) private func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r != 0 && (r < 0) != (b < 0) ? r + b : r
}

/// Python `a // b` for ints: floor division. Module-wide: the GitHub face's
/// `ggen.py` port divides the same way.
@inline(__always) func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0) && ((a < 0) != (b < 0)) ? q - 1 : q
}

/// Python float `a ** 2`.
@inline(__always) private func sq(_ value: Double) -> Double { pow(value, 2) }

// MARK: - Frames

/// `S`
private let S = 16

/// A frame: a 16x16 grid of colours, nil = unlit (`blank()`).
struct WeatherIconFrame {
    var px: [Pixel?] = Array(repeating: nil, count: S * S)

    subscript(x: Int, y: Int) -> Pixel? {
        get { px[y * S + x] }
        set { px[y * S + x] = newValue }
    }

    /// `put(f, x, y, c)`
    mutating func put(_ x: Int, _ y: Int, _ c: Pixel?) {
        if 0 <= x, x < S, 0 <= y, y < S, let c { self[x, y] = c }
    }

    var canvas: PixelCanvas {
        var canvas = PixelCanvas(width: S, height: S)
        for y in 0..<S {
            for x in 0..<S {
                if let c = self[x, y] { canvas[x, y] = c }
            }
        }
        return canvas
    }
}

private typealias Frames = [(WeatherIconFrame, Int)]

/// `hexrgb`
private func hexrgb(_ hex: String) -> Pixel {
    let v = UInt32(hex.dropFirst(), radix: 16)!
    return Pixel(red: UInt8(v >> 16 & 0xFF), green: UInt8(v >> 8 & 0xFF), blue: UInt8(v & 0xFF))
}

/// `C`, both waves merged.
private let C: [String: Pixel] = [
    "sun": "#FFD23A", "sun_edge": "#FF9F1C", "ray": "#FFB52E", "ray_dim": "#8A5A10",
    "moon": "#F4EBB8", "moon_edge": "#B8AC72", "star": "#FFFFFF", "star_dim": "#5A5A70",
    "cl_hi": "#FFFFFF", "cl": "#D5DBE5", "cl_lo": "#8E98A8",
    "dk_hi": "#A9B2C0", "dk": "#78818F", "dk_lo": "#4E5563",
    "nt_hi": "#9AA4B8", "nt": "#6C7588", "nt_lo": "#444B5C",
    "drop": "#4DA6FF", "drop_tail": "#1F5FB8", "drizzle": "#7CC4FF",
    "snow": "#FFFFFF", "snow_dim": "#9FB4CC",
    "ice": "#8EE6FF", "ice_dim": "#3A8FB0",
    "fog": "#B3BAC6", "fog_dim": "#6E7684",
    "bolt": "#FFE14D", "bolt_core": "#FFFFFF",
    "hum": "#3BA0FF", "hum_lo": "#1C5FA8", "hum_hi": "#A8DAFF", "hum_empty": "#0E2A4A",
    "wind": "#CFE8F0", "wind_dim": "#5E7C88",
    "therm": "#E8E8E8", "therm_hot": "#FF5A3C", "therm_cold": "#3C9CFF",
    // wave 2
    "streak": "#F2FAFF", "streak_dim": "#8AAAB8", "frost_ray": "#9FDCF0", "frost_ray_dim": "#3F7A90",
    "hail": "#F2F8FF", "hail_dim": "#8FA6BF",
    "hot": "#FF6A1C", "hot_core": "#FFD84A", "shimmer": "#FF8C3A", "shimmer_dim": "#6A2A08",
    "cold_sun": "#FFF2B0", "cold_edge": "#C9D8E8",
    "earthshine": "#262634",
    "horizon": "#8A6A3A", "umbrella": "#FF4F6D", "umbrella_dk": "#A82A40", "handle": "#C8C8C8",
    "uv": "#B45AFF", "uv_dim": "#5A2A88",
].mapValues(hexrgb)

/// `C[name]`
private func c(_ name: String) -> Pixel { C[name]! }

// MARK: - Primitives

/// `sprite(f, rows, x, y, c)`
private func sprite(_ f: inout WeatherIconFrame, _ rows: [String], _ x: Int, _ y: Int, _ col: Pixel) {
    for (dy, row) in rows.enumerated() {
        for (dx, ch) in row.enumerated() where ch == "#" {
            f.put(x + dx, y + dy, col)
        }
    }
}

/// `disc(f, cx, cy, r, core, edge)`
private func disc(_ f: inout WeatherIconFrame, _ cx: Double, _ cy: Double, _ r: Double, _ core: Pixel, _ edge: Pixel) {
    for y in 0..<S {
        for x in 0..<S {
            let d2 = sq(Double(x) - cx) + sq(Double(y) - cy)
            if d2 <= r * r {
                f.put(x, y, d2 > sq(r - 1.1) ? edge : core)
            }
        }
    }
}

/// `CLOUD_BIG`, `CLOUD_SMALL`: (cx, cy, r)
private let CLOUD_BIG: [(Double, Double, Double)] = [(5.0, 3.6, 3.4), (9.4, 4.6, 2.9), (2.4, 5.6, 2.2), (12.0, 6.0, 1.9)]
private let CLOUD_SMALL: [(Double, Double, Double)] = [(3.6, 2.6, 2.5), (6.8, 3.4, 2.1), (1.6, 4.0, 1.6), (8.8, 4.2, 1.4)]

/// `cloud_mask(circles, base, x0, x1)`
private func cloudMask(_ circles: [(Double, Double, Double)], _ base: Int, _ x0: Int, _ x1: Int) -> (Int, Int) -> Bool {
    { x, y in
        if y > base { return false }
        if circles.contains(where: { cx, cy, r in sq(Double(x) - cx) + sq(Double(y) - cy) <= r * r }) {
            return true
        }
        return x0 <= x && x <= x1 && y >= base - 2
    }
}

/// `cloud(f, ox, oy, tone="cl", size="big")`
private func cloud(_ f: inout WeatherIconFrame, _ ox: Int, _ oy: Int, _ tone: String = "cl", _ size: String = "big") {
    let inside: (Int, Int) -> Bool
    let w: Int, h: Int
    if size == "big" {
        inside = cloudMask(CLOUD_BIG, 7, 1, 13)
        (w, h) = (15, 8)
    } else {
        inside = cloudMask(CLOUD_SMALL, 5, 0, 9)
        (w, h) = (11, 6)
    }
    let hi = c(tone + "_hi"), mid = c(tone), lo = c(tone + "_lo")
    for y in 0..<h {
        for x in 0..<w {
            if !inside(x, y) { continue }
            let col: Pixel
            if !inside(x, y - 1) {
                col = hi
            } else if !inside(x, y + 1) {
                col = lo
            } else {
                col = mid
            }
            f.put(ox + x, oy + y, col)
        }
    }
}

/// `sun(f, cx, cy, r, phase, ray_len=2)` — rays breathe: orthogonal and
/// diagonal rays trade length with `phase`.
private func sun(_ f: inout WeatherIconFrame, _ cx: Double, _ cy: Double, _ r: Double, _ phase: Int, rayLen: Int = 2) {
    disc(&f, cx, cy, r, c("sun"), c("sun_edge"))
    let ortho = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    let diag = [(1, -1), (1, 1), (-1, 1), (-1, -1)]
    let longO = phase == 0 || phase == 1
    let longD = phase == 1 || phase == 2
    for (dx, dy) in ortho {
        let n = longO ? rayLen : rayLen - 1
        for k in 0..<max(n, 0) {
            let d = r + 1.6 + Double(k)
            f.put(
                pyRound(cx + Double(dx) * d - 0.5 + (dx == 0 ? 0.5 : 0)),
                pyRound(cy + Double(dy) * d - 0.5 + (dy == 0 ? 0.5 : 0)),
                k == 0 || longO ? c("ray") : c("ray_dim"))
        }
    }
    for (dx, dy) in diag {
        let n = longD ? rayLen - 1 : 1
        for k in 0..<max(n, 1) {
            let d = (r + 1.2 + Double(k)) / 1.414
            f.put(pyRound(cx + Double(dx) * d), pyRound(cy + Double(dy) * d),
                  longD || k == 0 ? c("ray") : c("ray_dim"))
        }
    }
}

/// `moon(f, cx, cy, r, cut_dx, cut_dy, cut_r)`
private func moon(
    _ f: inout WeatherIconFrame, _ cx: Double, _ cy: Double, _ r: Double,
    _ cutDx: Double, _ cutDy: Double, _ cutR: Double
) {
    for y in 0..<S {
        for x in 0..<S {
            let d2 = sq(Double(x) - cx) + sq(Double(y) - cy)
            if d2 <= r * r && sq(Double(x) - cx - cutDx) + sq(Double(y) - cy - cutDy) > cutR * cutR {
                let edge = d2 > sq(r - 1.1)
                f.put(x, y, edge ? c("moon_edge") : c("moon"))
            }
        }
    }
}

/// `star(f, x, y, level)` — level 0 off, 1 dim dot, 2 bright dot, 3 bright cross.
private func star(_ f: inout WeatherIconFrame, _ x: Int, _ y: Int, _ level: Int) {
    if level == 0 { return }
    f.put(x, y, level >= 2 ? c("star") : c("star_dim"))
    if level == 3 {
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            f.put(x + dx, y + dy, c("star_dim"))
        }
    }
}

/// `drops(f, t, columns, top, bottom, length, speed, head, tail)`
private func drops(
    _ f: inout WeatherIconFrame, _ t: Int, _ columns: [(Int, Int)], _ top: Int, _ bottom: Int,
    _ length: Int, _ speed: Int, _ head: Pixel, _ tail: Pixel
) {
    let span = bottom - top + 1 + length
    for (col, off) in columns {
        let y = top + floorMod(t * speed + off, span) - length
        for k in 0..<length {
            let yy = y + k
            if top <= yy && yy <= bottom {
                f.put(col, yy, k == length - 1 ? head : tail)
            }
        }
    }
}

/// `flakes(f, t, seeds, top, bottom)`
private func flakes(_ f: inout WeatherIconFrame, _ t: Int, _ seeds: [(Int, Int, Int)], _ top: Int, _ bottom: Int) {
    let span = bottom - top + 1
    for (x0, off, wob) in seeds {
        let y = top + floorMod(t + off, span)
        let x = x0 + (floorMod(t + wob, 4) < 2 ? 1 : 0)
        f.put(x, y, floorMod(t + off, 3) != 0 ? c("snow") : c("snow_dim"))
    }
}

/// `BOLT`
private let BOLT = [
    "...##",
    "..##.",
    ".##..",
    "####.",
    "..##.",
    ".##..",
    ".#...",
    "#....",
]

/// `bolt(f, x, y, bright)`
private func bolt(_ f: inout WeatherIconFrame, _ x: Int, _ y: Int, _ bright: Bool) {
    sprite(&f, BOLT, x, y, bright ? c("bolt_core") : c("bolt"))
    if bright {
        sprite(&f, BOLT, x + 1, y, c("bolt"))
    }
}

/// `streaks(f, t, lines)` — wind: short bright dashes racing left to right.
/// lines = [(y, len, speed, off)].
private func streaks(_ f: inout WeatherIconFrame, _ t: Int, _ lines: [(Int, Int, Int, Int)]) {
    for (y, n, speed, off) in lines {
        let x0 = floorMod(t * speed + off, S + n) - n
        for k in 0..<n {
            f.put(x0 + k, y, k >= n - 2 ? c("streak") : c("streak_dim"))
        }
    }
}

/// `slanted(f, t, columns, top, bottom, length, speed, head, tail, slant=1)` —
/// rain driven by wind: each drop moves `slant` px left per `speed` px down.
private func slanted(
    _ f: inout WeatherIconFrame, _ t: Int, _ columns: [(Int, Int)], _ top: Int, _ bottom: Int,
    _ length: Int, _ speed: Int, _ head: Pixel, _ tail: Pixel, slant: Int = 1
) {
    let span = bottom - top + 1 + length
    for (col, off) in columns {
        let p = floorMod(t * speed + off, span)
        for k in 0..<length {
            let y = top + p - length + k
            let x = col - floorDiv(p - length + k, 2) * slant
            if top <= y && y <= bottom {
                f.put(x, y, k == length - 1 ? head : tail)
            }
        }
    }
}

// MARK: - Icons (wave 1)

/// `clear_day()`
private func clearDay() -> Frames {
    (0..<4).map { p in
        var f = WeatherIconFrame()
        sun(&f, 7.5, 7.5, 3.9, p, rayLen: 2)
        return (f, 300)
    }
}

/// `clear_night()`
private func clearNight() -> Frames {
    let levels = [[1, 2, 3, 2, 1, 1], [2, 1, 1, 2, 3, 2], [3, 2, 1, 1, 1, 2]]
    let pos = [(12, 2), (14, 8), (11, 13)]
    return (0..<6).map { t in
        var f = WeatherIconFrame()
        moon(&f, 6.5, 8.0, 5.8, 3.4, -2.6, 4.9)
        for ((x, y), lv) in zip(pos, levels) {
            star(&f, x, y, lv[t])
        }
        return (f, 350)
    }
}

/// `partly_cloudy(night)`
private func partlyCloudy(_ night: Bool) -> Frames {
    let drift = [0, 0, 1, 1, 1, 1, 0, 0]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        if night {
            moon(&f, 5.5, 5.5, 4.4, 2.6, -2.0, 3.8)
            star(&f, 13, 2, [3, 2, 1, 1, 2, 3, 2, 1][t])
        } else {
            sun(&f, 5.5, 5.5, 3.5, t % 4, rayLen: 2)
        }
        cloud(&f, 1 + drift[t], 8, night ? "nt" : "cl")
        return (f, 280)
    }
}

/// `cloudy(night)`
private func cloudy(_ night: Bool) -> Frames {
    let back = [0, 0, -1, -1, -1, -1, 0, 0]
    let front = [0, 0, 1, 1, 1, 1, 0, 0]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        if night {
            star(&f, 2, 2, [1, 2, 3, 2, 1, 1, 1, 1][t])
        }
        cloud(&f, 5 + back[t], 1, night ? "nt" : "dk", "small")
        cloud(&f, 0 + front[t], 7, night ? "nt" : "cl")
        return (f, 300)
    }
}

/// `fog()`
private func fog() -> Frames {
    let bars = [(2, 1, 11), (5, 3, 12), (8, 0, 10), (11, 2, 12), (14, 1, 9)]
    let shifts = [0, 1, 1, 0, 0, -1, -1, 0]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        for (i, (y, x, n)) in bars.enumerated() {
            let shift = shifts[floorMod(t + i * 2, 8)]
            for k in 0..<n {
                f.put(x + k + shift, y, i % 2 == 0 ? c("fog") : c("fog_dim"))
            }
        }
        return (f, 220)
    }
}

/// `rain(heavy=False, tone="cl")`
private func rain(heavy: Bool = false, tone: String = "cl") -> Frames {
    let cols = heavy ? [(2, 0), (5, 5), (8, 2), (11, 7), (14, 3)] : [(3, 0), (7, 4), (11, 2)]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, tone)
        drops(&f, t, cols, 9, 15, heavy ? 3 : 2, heavy ? 2 : 1, c("drop"), c("drop_tail"))
        return (f, heavy ? 90 : 130)
    }
}

/// `drizzle()`
private func drizzle() -> Frames {
    let cols = [(3, 0), (6, 3), (9, 1), (12, 4)]
    return (0..<6).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, "cl")
        let span = 6
        for (col, off) in cols {
            let y = 9 + floorMod(t + off, span)
            f.put(col, y, c("drizzle"))
        }
        return (f, 200)
    }
}

/// `snow()`
private func snow() -> Frames {
    let seeds = [(2, 0, 0), (6, 4, 1), (10, 2, 2), (13, 6, 3), (4, 5, 2), (8, 1, 3)]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, "cl")
        flakes(&f, t, seeds, 9, 15)
        return (f, 200)
    }
}

/// `FLAKE`, `TIPS`
private let FLAKE = [
    ".....#.....",
    "..#..#..#..",
    "...#.#.#...",
    "....###....",
    ".#...#...#.",
    "###########",
    ".#...#...#.",
    "....###....",
    "...#.#.#...",
    "..#..#..#..",
    ".....#.....",
]
private let TIPS = [(5, 0), (8, 1), (10, 5), (8, 9), (5, 10), (2, 9), (0, 5), (2, 1)]

/// `frost()` — the frost creeps: a bright wave runs out along the arms.
private func frost() -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        sprite(&f, FLAKE, 2, 2, c("ice_dim"))
        for (y, row) in FLAKE.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                let ring = max(abs(x - 5), abs(y - 5))
                if ring == t % 6 || ring == (t + 3) % 6 {
                    f.put(2 + x, 2 + y, c("ice"))
                }
            }
        }
        let (tx, ty) = TIPS[t]
        f.put(2 + tx, 2 + ty, c("star"))
        return (f, 170)
    }
}

/// `thunder(storm=False)`
private func thunder(storm: Bool = false) -> Frames {
    let seq = [(0, 500), (2, 70), (0, 70), (1, 220), (0, 600)]
    var out: Frames = []
    var t = 0
    for (strike, ms) in seq {
        let steps = storm ? max(1, floorDiv(ms, 90)) : 1
        for _ in 0..<steps {
            var f = WeatherIconFrame()
            cloud(&f, 0, 0, strike == 0 ? "dk" : "cl")
            if storm {
                drops(&f, t, [(2, 0), (13, 3), (4, 5), (11, 1)], 9, 15, 3, 2, c("drop"), c("drop_tail"))
            }
            if strike != 0 {
                bolt(&f, 5, 8, strike == 2)
            }
            out.append((f, floorDiv(ms, steps)))
            t += 1
        }
    }
    return out
}

// MARK: - Page icons

/// `DROP`
private let DROP = [
    "......##......",
    ".....####.....",
    "....######....",
    "...########...",
    "..##########..",
    ".############.",
    ".############.",
    "##############",
    "##############",
    "##############",
    ".############.",
    "..##########..",
    "....######....",
]

/// `humidity(level)` — a drop that fills to `level` percent with a rippling surface.
private func humidity(_ level: Int) -> Frames {
    let filled = 12 - pyRound(Double(level) / 100 * 11)
    let grid = DROP.map { Array($0) }
    return (0..<6).map { t in
        var f = WeatherIconFrame()
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() {
                if ch != "#" { continue }
                let edge = x == 0 || row[x - 1] != "#" || x == row.count - 1 || row[x + 1] != "#"
                    || y == 0 || grid[y - 1][x] != "#" || y == grid.count - 1 || grid[y + 1][x] != "#"
                let surface = filled + (floorMod(x + t, 6) < 3 ? 1 : 0)
                let col: Pixel
                if y >= surface {
                    col = y == surface ? c("hum_hi") : c("hum")
                } else {
                    col = edge ? c("hum_lo") : c("hum_empty")
                }
                f.put(1 + x, 2 + y, col)
            }
        }
        return (f, 180)
    }
}

/// `WIND_LINES`: (y, x, n, curl)
private let WIND_LINES = [(3, 1, 10, true), (7, 3, 12, false), (11, 0, 9, true)]

/// `wind()`
private func wind() -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        for (i, (y, x, n, curl)) in WIND_LINES.enumerated() {
            let off = floorMod(t + i * 3, 8)
            for k in 0..<n {
                let lit = floorMod(k - off, 8) < 5
                f.put(x + k, y, lit ? c("wind") : c("wind_dim"))
            }
            if curl {
                let ex = x + n
                f.put(ex, y - 1, c("wind"))
                f.put(ex + 1, y - 2, c("wind"))
                f.put(ex, y - 3, c("wind_dim"))
            }
        }
        return (f, 120)
    }
}

/// `THERM`
private let THERM = [
    ".###.",
    ".#.#.",
    ".#.#.",
    ".#.#.",
    ".#.#.",
    ".#.#.",
    ".#.#.",
    ".#.#.",
    "##.##",
    "#...#",
    "#...#",
    "##.##",
    ".###.",
]

/// `thermometer(warm)`
private func thermometer(_ warm: Bool) -> Frames {
    let ink = warm ? c("therm_hot") : c("therm_cold")
    return (0..<6).map { t in
        var f = WeatherIconFrame()
        sprite(&f, THERM, 5, 1, c("therm"))
        let level = 5 + [0, 1, 2, 2, 1, 0][t]
        for y in (13 - level)..<13 {
            f.put(7, y, ink)
        }
        for y in 10..<12 {
            for x in 6..<9 {
                f.put(x, y, ink)
            }
        }
        for (k, y) in [3, 6, 9].enumerated() {
            f.put(11, y, k % 2 == 0 ? c("therm") : c("star_dim"))
            f.put(12, y, c("star_dim"))
        }
        return (f, 220)
    }
}

// MARK: - Icons (wave 2: every WMO state, plus derived states)

/// `mainly_clear(night)`
private func mainlyClear(_ night: Bool) -> Frames {
    let drift = [0, 0, 1, 1, 2, 2, 1, 1]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        if night {
            moon(&f, 6.5, 6.5, 5.2, 3.0, -2.4, 4.4)
            star(&f, 14, 2, [1, 2, 3, 2, 1, 1, 2, 1][t])
        } else {
            sun(&f, 6.5, 6.5, 3.6, t % 4, rayLen: 2)
        }
        cloud(&f, 5 + drift[t], 10, night ? "nt" : "cl", "small")
        return (f, 300)
    }
}

/// `windy(kind)`
private func windy(_ kind: String) -> Frames {
    let lines = [(9, 8, 3, 0), (11, 10, 2, 7), (13, 7, 3, 11), (15, 9, 2, 4)]
    return (0..<10).map { t in
        var f = WeatherIconFrame()
        if kind == "day" {
            sun(&f, 5.5, 4.5, 3.2, t % 4, rayLen: 1)
        } else if kind == "night" {
            moon(&f, 5.0, 4.5, 4.0, 2.4, -1.8, 3.4)
        } else {
            cloud(&f, [0, 0, 1, 1, 1, 0, 0, -1, -1, -1][t], 0, "cl")
        }
        streaks(&f, t, kind != "cloud" ? lines : [(10, 9, 3, 0), (12, 11, 2, 7), (14, 8, 3, 11)])
        return (f, 80)
    }
}

/// `showers(night, snow_=False)`
private func showers(_ night: Bool, snow snow_: Bool = false) -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        if night {
            moon(&f, 11.0, 4.0, 3.8, -2.2, -1.6, 3.2)
        } else {
            sun(&f, 11.0, 4.0, 3.0, t % 4, rayLen: 1)
        }
        cloud(&f, 0, 3, "cl")
        if snow_ {
            flakes(&f, t, [(2, 0, 0), (6, 3, 1), (10, 1, 2), (13, 4, 3)], 12, 15)
        } else {
            drops(&f, t, [(3, 0), (7, 2), (11, 1)], 12, 15, 2, 1, c("drop"), c("drop_tail"))
        }
        return (f, 150)
    }
}

/// `heavy_rain()`
private func heavyRain() -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, "dk")
        slanted(&f, t, [(3, 0), (6, 4), (9, 2), (12, 6), (15, 3), (5, 7), (11, 5)], 8, 15, 3, 2,
                c("drop"), c("drop_tail"))
        return (f, 70)
    }
}

/// `blizzard()`
private func blizzard() -> Frames {
    let seeds = [(4, 0), (8, 3), (12, 1), (15, 5), (6, 6), (10, 2), (14, 7), (2, 4)]
    return (0..<10).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, "dk")
        for (x0, off) in seeds {
            let p = floorMod(t + off, 8)
            f.put(x0 - p, 8 + p, floorMod(t + off, 3) != 0 ? c("snow") : c("snow_dim"))
        }
        streaks(&f, t, [(11, 4, 3, 5), (14, 5, 3, 0)])
        return (f, 90)
    }
}

/// `sleet()`
private func sleet() -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, "cl")
        drops(&f, t, [(3, 0), (11, 4)], 9, 15, 2, 1, c("drop"), c("drop_tail"))
        flakes(&f, t, [(6, 2, 0), (13, 6, 2)], 9, 15)
        return (f, 150)
    }
}

/// `freezing_rain()` — drops fall blue and land as ice: a glittering glaze on the ground.
private func freezingRain() -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        cloud(&f, 0, 0, "cl")
        drops(&f, t, [(3, 0), (7, 3), (11, 1)], 9, 14, 2, 1, c("ice"), c("ice_dim"))
        for x in 1..<15 {
            f.put(x, 15, floorMod(x + t * 3, 7) == 0 ? c("star") : c("ice_dim"))
        }
        return (f, 140)
    }
}

/// `hail()` — thunderstorm with hail: pellets bounce off the ground, the bolt strikes.
private func hail() -> Frames {
    (0..<10).map { t in
        var f = WeatherIconFrame()
        let strike = t == 6 || t == 7
        cloud(&f, 0, 0, strike ? "cl" : "dk")
        for (col, off) in [(3, 0), (8, 3), (12, 6), (6, 8)] {
            let p = floorMod(t * 2 + off, 10)
            let y = p <= 6 ? 9 + p : 15 - (p - 6)   // fall, then a small bounce
            f.put(col + (p > 6 ? 1 : 0), y, c("hail"))
        }
        if strike {
            bolt(&f, 9, 8, t == 6)
        }
        return (f, 110)
    }
}

/// `rime_fog()`
private func rimeFog() -> Frames {
    let sparks = [(3, 3), (12, 6), (6, 9), (14, 12), (2, 13)]
    return fog().enumerated().map { t, frame in
        var g = frame.0
        for (i, (x, y)) in sparks.enumerated() {
            if floorMod(t + i * 2, 5) == 0 {
                g.put(x, y, c("star"))
            } else if floorMod(t + i * 2, 5) == 1 {
                g.put(x, y, c("ice"))
            }
        }
        return (g, frame.1)
    }
}

/// `hot()` — heat: a swollen red sun and air shimmering above the ground.
private func hot() -> Frames {
    (0..<8).map { t in
        var f = WeatherIconFrame()
        disc(&f, 7.5, 6.0, 4.6, c("hot_core"), c("hot"))
        for (k, (dx, dy)) in [(0, -1), (1, -1), (1, 0), (-1, -1), (-1, 0)].enumerated() {
            let d = floorMod(t + k, 2) != 0 ? 6.4 : 5.8
            let div = dx != 0 && dy != 0 ? 1.414 : 1.0
            f.put(pyRound(7.5 + Double(dx) * d / div), pyRound(6 + Double(dy) * d / div), c("hot"))
        }
        for (row, y) in [12, 14].enumerated() {
            for x in 1..<15 {
                let wave = sin((Double(x) + Double(t) * 1.0 + Double(row * 2)) * 0.9)
                f.put(x, y + (wave > 0.4 ? 1 : 0), wave > -0.2 ? c("shimmer") : c("shimmer_dim"))
            }
        }
        return (f, 140)
    }
}

/// `frosty_clear()` — clear and freezing: a pale winter sun, ice crystals glinting around it.
private func frostyClear() -> Frames {
    let glints = [(1, 2), (14, 3), (13, 13), (2, 12), (8, 15)]
    let recolour: [Pixel: Pixel] = [
        c("sun"): c("cold_sun"), c("sun_edge"): c("cold_edge"),
        c("ray"): c("frost_ray"), c("ray_dim"): c("frost_ray_dim"),
    ]
    return (0..<6).map { t in
        var f = WeatherIconFrame()
        sun(&f, 7.5, 7.5, 3.9, t % 4, rayLen: 2)
        for y in 0..<S {
            for x in 0..<S {
                if let v = f[x, y] { f[x, y] = recolour[v] ?? v }
            }
        }
        for (i, (x, y)) in glints.enumerated() {
            let lv = floorMod(t + i, 6)
            if (lv == 0 || lv == 1) && f[x, y] == nil {
                star(&f, x, y, lv == 0 ? 3 : 2)
            } else if lv == 2 {
                f.put(x, y, c("ice"))
            }
        }
        return (f, 260)
    }
}

/// `moon_phase(age)` — age in [0,1): 0 new, .25 first quarter (right lit), .5 full, .75 last.
private func moonPhase(_ age: Double) -> Frames {
    let k = cos(2 * Double.pi * age)
    let stars = [(1, 2), (14, 1), (13, 14)]
    return (0..<6).map { t in
        var f = WeatherIconFrame()
        let (cx, cy, r) = (7.5, 7.5, 5.6)
        for y in 0..<S {
            for x in 0..<S {
                let nx = (Double(x) - cx) / r, ny = (Double(y) - cy) / r
                if nx * nx + ny * ny > 1 { continue }
                let s = sqrt(max(0.0, 1 - ny * ny))
                let lit = age < 0.5 ? nx > k * s : nx < -k * s
                let edge = nx * nx + ny * ny > sq(1 - 1.1 / r)
                f.put(x, y, lit ? (edge ? c("moon_edge") : c("moon")) : c("earthshine"))
            }
        }
        for (i, (x, y)) in stars.enumerated() {
            star(&f, x, y, [1, 2, 3, 2, 1, 0][floorMod(t + i * 2, 6)])
        }
        return (f, 350)
    }
}

/// `sun_event(rise)` — the sun climbing out of (or sinking into) the horizon.
private func sunEvent(_ rise: Bool) -> Frames {
    let path = rise ? [3, 2, 1, 0, 0, 0, 1, 2] : [0, 1, 2, 3, 3, 3, 2, 1]
    return (0..<8).map { t in
        var f = WeatherIconFrame()
        let cy = 9.5 + Double(path[t])
        for y in 0..<S {
            for x in 0..<S where y <= 11 {
                let d2 = sq(Double(x) - 7.5) + sq(Double(y) - cy)
                if d2 <= sq(4.2) {
                    f.put(x, y, d2 > sq(3.1) ? c("sun_edge") : c("sun"))
                }
            }
        }
        for x in 0..<S {
            f.put(x, 12, c("horizon"))
        }
        let arrowRows = rise ? [".#.", "###"] : ["###", ".#."]
        sprite(&f, arrowRows, 6, 14, c("ray"))
        f.put(7, rise ? 13 : 15, c("ray_dim"))
        return (f, 260)
    }
}

/// `UMBRELLA`
private let UMBRELLA = [
    "......##......",
    "....######....",
    "..##########..",
    ".############.",
    "##############",
    "#..#..#..#..#.",
]

/// `umbrella()`
private func umbrella() -> Frames {
    (0..<6).map { t in
        var f = WeatherIconFrame()
        sprite(&f, UMBRELLA, 1, 3, c("umbrella"))
        sprite(&f, [UMBRELLA[4]], 1, 7, c("umbrella_dk"))
        for y in 8..<14 {
            f.put(7, y, c("handle"))
        }
        f.put(6, 14, c("handle")); f.put(5, 13, c("handle"))
        for (col, off) in [(2, 0), (12, 2), (4, 1)] {
            let y = floorMod(t + off, 3)
            f.put(col, y, c("drop"))
        }
        return (f, 180)
    }
}

/// `uv_icon()` — violet rays: the part of sunlight you cannot see.
private func uvIcon() -> Frames {
    (0..<4).map { t in
        var f = WeatherIconFrame()
        sun(&f, 7.5, 7.5, 3.9, t, rayLen: 2)
        for y in 0..<S {
            for x in 0..<S {
                if f[x, y] == c("ray") {
                    f[x, y] = c("uv")
                } else if f[x, y] == c("ray_dim") {
                    f[x, y] = c("uv_dim")
                }
            }
        }
        return (f, 300)
    }
}

/// `wgen.nodata_icon()` — the grey night cloud, still.
private func nodata() -> Frames {
    var f = WeatherIconFrame()
    cloud(&f, 0, 4, "nt")
    return [(f, 1000)]
}

// MARK: - Catalogue

/// `THEMES | DERIVED | MOON | PAGE_ICONS | {"nodata"}` — the builder per icon.
/// A free function rather than a `WeatherIcon` member, so the builders' Python
/// names (`fog()`, `rain()`) are not shadowed by the enum's cases.
func weatherIconArt(_ icon: WeatherIcon) -> [(canvas: PixelCanvas, milliseconds: Int)] {
    let frames: Frames
    switch icon {
    case .clearDay: frames = clearDay()
    case .clearNight: frames = clearNight()
    case .partlyCloudyDay: frames = partlyCloudy(false)
    case .partlyCloudyNight: frames = partlyCloudy(true)
    case .cloudDay: frames = cloudy(false)
    case .cloudNight: frames = cloudy(true)
    case .fog: frames = fog()
    case .drizzle: frames = drizzle()
    case .rain: frames = rain()
    case .snow: frames = snow()
    case .frost: frames = frost()
    case .thunder: frames = thunder()
    case .storm: frames = thunder(storm: true)
    case .mainlyClearDay: frames = mainlyClear(false)
    case .mainlyClearNight: frames = mainlyClear(true)
    case .showersDay: frames = showers(false)
    case .showersNight: frames = showers(true)
    case .heavyRain: frames = heavyRain()
    case .sleet: frames = sleet()
    case .freezingRain: frames = freezingRain()
    case .snowShowersDay: frames = showers(false, snow: true)
    case .snowShowersNight: frames = showers(true, snow: true)
    case .hail: frames = hail()
    case .rimeFog: frames = rimeFog()
    case .windyDay: frames = windy("day")
    case .windyNight: frames = windy("night")
    case .cloudWindy: frames = windy("cloud")
    case .blizzard: frames = blizzard()
    case .hot: frames = hot()
    case .frostyClear: frames = frostyClear()
    case .moon0: frames = moonPhase(0.0 / 8)
    case .moon1: frames = moonPhase(1.0 / 8)
    case .moon2: frames = moonPhase(2.0 / 8)
    case .moon3: frames = moonPhase(3.0 / 8)
    case .moon4: frames = moonPhase(4.0 / 8)
    case .moon5: frames = moonPhase(5.0 / 8)
    case .moon6: frames = moonPhase(6.0 / 8)
    case .moon7: frames = moonPhase(7.0 / 8)
    case .humidity: frames = humidity(70)
    case .wind: frames = wind()
    case .feelsWarm: frames = thermometer(true)
    case .feelsCold: frames = thermometer(false)
    case .sunrise: frames = sunEvent(true)
    case .sunset: frames = sunEvent(false)
    case .umbrella: frames = umbrella()
    case .uv: frames = uvIcon()
    case .nodata: frames = nodata()
    }
    return frames.map { (canvas: $0.0.canvas, milliseconds: $0.1) }
}
