// The user's pixel-art alarm clock as the menu bar glyph: the transcription
// approved out of the candidates (`userclock-dark-online`, `userclock-light-
// offline`, … in icons-candidates/menubar). This file is the map's single
// home — `Scripts/MakeIcon.swift` is compiled alongside it and ships what it
// rasterizes, so the art on the bar and the art the generator writes cannot
// drift apart.
//
// Deliberately free of AppKit: a map and a palette are data, and data is what
// the golden tests pin. Turning a raster into CG pixels lives in the generator.

enum UserClock {
    /// Which colour a character of the map carries, 0xRRGGBB. An absent
    /// character, or one carried as `nil`, is a transparent pixel.
    typealias Palette = [Character: UInt32?]
    /// The clock, one character per art pixel and one art pixel per point —
    /// 1, 2 and 3 device pixels at @1x, @2x and @3x, so every scale renders
    /// the same map with no resampling.
    ///
    /// Measured off the source: an art pixel is 21.4 x 20.9 source pixels, so
    /// the map's square pixels keep the frame's 19:11 within 3%. The frame has
    /// two-step corners top and bottom and a double top bar; the screen is a
    /// 1pt margin ring (`M`) around six LED rows (`S`); the sliders stand 4pt
    /// apart with 3pt knobs — blue and white on the fourth LED row, purple on
    /// the third. The body is centred on the canvas; the sparkles hang off its
    /// top right.
    ///
    ///     F frame        T top blocks and feet (shaded darker in the source)
    ///     M screen margin S screen LED area
    ///     b w p  blue, white, purple slider    * sparkle
    ///
    /// The transcription is the BOLD reading: at one point per art pixel the
    /// approved art read wispy next to the SF Symbols beside it, so every
    /// stroke that carried one pixel carries two — the slider stems are two
    /// columns wide, and the bottom wall takes the same second row the top
    /// bar has always had, with the feet one row lower for it. The canvas
    /// absorbs both; nothing grew past 21x18.
    static let map = [
        "................**...",
        "................**.*.",
        "..........T.......*..",
        "........T.T.T.......*",
        "...FFFFFFFFFFFFFFF...",
        "..FFFFFFFFFFFFFFFFF..",
        ".FFMMMMMMMMMMMMMMMFF.",
        ".FMSSSbbSSwwSSppSSMF.",
        ".FMSSSbbSSwwSSppSSMF.",
        ".FMSSSbbSSwwSpppSSMF.",
        ".FMSSbbbSwwwSSppSSMF.",
        ".FMSSSbbSSwwSSppSSMF.",
        ".FMSSSbbSSwwSSppSSMF.",
        ".FFMMMMMMMMMMMMMMMFF.",
        "..FFFFFFFFFFFFFFFFF..",
        "..FFFFFFFFFFFFFFFFF..",
        "....TT.........TT....",
        ".....................",
    ]
    static let width = 21
    static let height = 18

    /// The glyph as device pixels: one 0xRRGGBB per pixel, 0 where it stays
    /// empty, rows top-down. A pure function of its arguments — the same map,
    /// palette and scale answer the same raster everywhere, which is what both
    /// the generator's PNGs and the golden tests stand on.
    struct Raster: Equatable {
        let width: Int
        let height: Int
        let pixels: [UInt32]

        func pixel(x: Int, y: Int) -> UInt32 {
            pixels[y * width + x]
        }
    }

    static func raster(palette: Palette, scale: Int) -> Raster {
        precondition(scale >= 1, "an art pixel is at least one device pixel")
        var pixels = [UInt32](repeating: 0, count: width * scale * height * scale)
        for (row, line) in map.enumerated() {
            for (col, character) in line.enumerated() {
                guard let hex = palette[character] ?? nil else { continue }
                for y in row * scale..<(row + 1) * scale {
                    let base = y * width * scale
                    for x in col * scale..<(col + 1) * scale {
                        pixels[base + x] = hex
                    }
                }
            }
        }
        return Raster(width: width * scale, height: height * scale, pixels: pixels)
    }

    /// Offline keeps the clock and puts its screen out: the sliders grey and
    /// dimmed, the sparkles gone.
    static func offline(_ palette: Palette, slider: UInt32) -> Palette {
        var out = palette
        for key: Character in ["b", "w", "p"] { out[key] = slider }
        out["*"] = .some(nil)
        return out
    }

    /// The no-clock state keeps the clock and leaves its screen BLANK: no
    /// sliders, no sparkles — nothing has ever been shown on it. The frame,
    /// the shaded bevel and the feet stay, because the device is drawn, not
    /// its contents.
    static func empty(_ palette: Palette) -> Palette {
        var out = palette
        for key: Character in ["b", "w", "p", "*"] { out[key] = .some(nil) }
        return out
    }

    // The approved colours. Dark takes the source as drawn; light is the
    // "open screen" treatment — dark frame, no screen fill, the white slider
    // in the frame's ink, and the blue deepened only as far as 3:1 on the
    // light bar needs (purple already clears it and stays as drawn).
    static let darkOnline: Palette = [
        "F": 0xD0D2DC, "T": 0xB3B6C3, "M": 0x0C0D10, "S": 0x0C0D10,
        "b": 0x4FBAF6, "w": 0xEDEEF2, "p": 0xBE55F9, "*": 0x66D0FA,
    ]
    static let darkOffline: Palette = offline(darkOnline, slider: 0x5C5E66)
    static let lightOnline: Palette = [
        "F": 0x1D1D1F, "T": 0x3A3A3F, "M": nil, "S": nil,
        "b": 0x0A7FC2, "w": 0x1D1D1F, "p": 0xBE55F9, "*": 0x0A7FC2,
    ]
    static let lightOffline: Palette = offline(lightOnline, slider: 0xA1A1A6)
}
