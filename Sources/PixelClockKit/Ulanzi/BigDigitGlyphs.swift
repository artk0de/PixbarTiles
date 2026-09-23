/// The weather face's 5×9 temperature face — copied from the
/// `tc002-face-mockup` skill's `weather/wgen.py` (`B`) and held to it pixel
/// for pixel by `WeatherGlyphTests`. Change the design there, not here.
///
/// Nine rows for every glyph: the digits, `%`, `+`, `k`, `m` and `c` are five
/// columns, `-` and `°` three, `i` one, the GitHub star `★` nine — hence sixteen-bit
/// rows. Same bit convention as the other tables — rows top first,
/// **bit 0 the leftmost column** — written binary so each literal is the
/// glyph's own row mirrored.
extension PixelFont {
    static let bigGlyphs: [Character: (width: Int, rows: [UInt16])] = [
        "0": (5, [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110]),
        "1": (5, [0b00100, 0b00110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110]),
        "2": (5, [0b01110, 0b10001, 0b10000, 0b10000, 0b01000, 0b00100, 0b00010, 0b00001, 0b11111]),
        "3": (5, [0b01110, 0b10001, 0b10000, 0b10000, 0b01100, 0b10000, 0b10000, 0b10001, 0b01110]),
        "4": (5, [0b01000, 0b01100, 0b01010, 0b01001, 0b01001, 0b11111, 0b01000, 0b01000, 0b01000]),
        "5": (5, [0b11111, 0b00001, 0b00001, 0b01111, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110]),
        "6": (5, [0b01110, 0b00001, 0b00001, 0b01111, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110]),
        "7": (5, [0b11111, 0b10000, 0b10000, 0b01000, 0b00100, 0b00100, 0b00010, 0b00010, 0b00010]),
        "8": (5, [0b01110, 0b10001, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110]),
        "9": (5, [0b01110, 0b10001, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000, 0b01110]),
        "-": (3, [0b000, 0b000, 0b000, 0b000, 0b111, 0b000, 0b000, 0b000, 0b000]),
        "°": (3, [0b010, 0b101, 0b010, 0b000, 0b000, 0b000, 0b000, 0b000, 0b000]),
        "%": (5, [0b10011, 0b10011, 0b01000, 0b01000, 0b00100, 0b00010, 0b00010, 0b11001, 0b11001]),
        // The GitHub face's hero (github/ggen.py `B`, held to it by
        // `GitHubFaceOracleTests`): `+N`, `12k`, `1m`, and the big star.
        "+": (5, [0b00000, 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000, 0b00000]),
        "k": (5, [0b00001, 0b00001, 0b10001, 0b01001, 0b00101, 0b00011, 0b00101, 0b01001, 0b10001]),
        "m": (5, [0b00000, 0b00000, 0b00000, 0b01011, 0b10101, 0b10101, 0b10101, 0b10101, 0b10101]),
        "★": (9, [
            0b000010000, 0b000010000, 0b000111000, 0b111111111, 0b011111110,
            0b001111100, 0b001101100, 0b011000110, 0b010000010,
        ]),
        // The CI failure's hero `ci`, lowercase at x-height like `m`.
        "c": (5, [0b00000, 0b00000, 0b00000, 0b01110, 0b10001, 0b00001, 0b00001, 0b10001, 0b01110]),
        "i": (1, [0b0, 0b1, 0b0, 0b1, 0b1, 0b1, 0b1, 0b1, 0b1]),
    ]
}
