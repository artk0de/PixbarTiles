/// The weather face's 5×9 temperature face — copied from the
/// `tc002-face-mockup` skill's `weather/wgen.py` (`B`) and held to it pixel
/// for pixel by `WeatherGlyphTests`. Change the design there, not here.
///
/// Nine rows for every glyph: the digits and `%` are five columns, `-` and
/// `°` three. Same bit convention as the other tables — rows top first,
/// **bit 0 the leftmost column** — written binary so each literal is the
/// glyph's own row mirrored.
extension PixelFont {
    static let bigGlyphs: [Character: (width: Int, rows: [UInt8])] = [
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
    ]
}
