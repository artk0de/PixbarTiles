/// The shared usage face's glyphs — the approved design's table, copied from
/// the `tc002-face-mockup` skill's `gen.py` (`G`) and held to it pixel for
/// pixel by `UsageFaceOracleTests`. Change the design there, not here.
///
/// Five rows for EVERY glyph, lowercase included. The 3×5 `tiny` face puts
/// lowercase on a four-row x-height, and a four-row letter beside a five-row
/// digit reads as broken on the panel — so this face is its own, not a
/// variant of that one. The letters take their canonical shapes: `e` with a
/// bowl, a crossbar and an open tail, a two-storey `a`, `j` with its dot and
/// `g` with a descender; a box-shaped letter reads as a digit.
///
/// Widths by glyph: `:` `.` and space are one column, `w` and `m` five, every
/// other mark three. Same bit convention as the other tables — rows top
/// first, **bit 0 the leftmost column** — written binary so each literal is
/// the glyph's own row mirrored.
///
/// The set is what the face spells: digits, `%`, `-`, `:`, `.`, space, the
/// row labels `s` and `w`, `rst`, and every letter of the twelve month
/// abbreviations. `?` is not in the design — nothing the face draws spells
/// it — and is here only so the substitute rule has a shape to draw: the
/// `tiny` face's own question mark.
extension PixelFont {
    static let proportionalGlyphs: [Character: (width: Int, rows: [UInt8])] = [
        // Digits — the same bytes as `tiny`'s corrected digits.
        "0": (3, [0b111, 0b101, 0b101, 0b101, 0b111]),
        "1": (3, [0b011, 0b010, 0b010, 0b010, 0b111]),
        "2": (3, [0b111, 0b100, 0b111, 0b001, 0b111]),
        "3": (3, [0b111, 0b100, 0b111, 0b100, 0b111]),
        "4": (3, [0b101, 0b101, 0b111, 0b100, 0b100]),
        "5": (3, [0b111, 0b001, 0b111, 0b100, 0b111]),
        "6": (3, [0b111, 0b001, 0b111, 0b101, 0b111]),
        "7": (3, [0b111, 0b100, 0b100, 0b100, 0b100]),
        "8": (3, [0b111, 0b101, 0b111, 0b101, 0b111]),
        "9": (3, [0b111, 0b101, 0b111, 0b100, 0b111]),
        // Punctuation — the one-column marks are one column.
        "%": (3, [0b001, 0b100, 0b010, 0b001, 0b100]),
        "-": (3, [0b000, 0b000, 0b111, 0b000, 0b000]),
        ":": (1, [0b0, 0b1, 0b0, 0b1, 0b0]),
        ".": (1, [0b0, 0b0, 0b0, 0b0, 0b1]),
        " ": (1, [0b0, 0b0, 0b0, 0b0, 0b0]),
        "?": (3, [0b111, 0b100, 0b010, 0b000, 0b010]),
        // Lowercase, five rows tall.
        "a": (3, [0b011, 0b100, 0b110, 0b101, 0b110]),
        "b": (3, [0b001, 0b001, 0b011, 0b101, 0b011]),
        "c": (3, [0b110, 0b001, 0b001, 0b001, 0b110]),
        "d": (3, [0b100, 0b100, 0b110, 0b101, 0b110]),
        "e": (3, [0b010, 0b101, 0b111, 0b001, 0b110]),
        "f": (3, [0b110, 0b001, 0b111, 0b001, 0b001]),
        "g": (3, [0b110, 0b101, 0b110, 0b100, 0b011]),
        "j": (3, [0b100, 0b000, 0b100, 0b101, 0b010]),
        "l": (3, [0b001, 0b001, 0b001, 0b001, 0b110]),
        "m": (5, [0b01011, 0b10101, 0b10101, 0b10101, 0b10101]),
        "n": (3, [0b011, 0b101, 0b101, 0b101, 0b101]),
        "o": (3, [0b010, 0b101, 0b101, 0b101, 0b010]),
        "p": (3, [0b011, 0b101, 0b011, 0b001, 0b001]),
        "r": (3, [0b110, 0b001, 0b001, 0b001, 0b001]),
        "s": (3, [0b110, 0b001, 0b010, 0b100, 0b011]),
        "t": (3, [0b010, 0b111, 0b010, 0b010, 0b110]),
        "u": (3, [0b101, 0b101, 0b101, 0b101, 0b110]),
        "v": (3, [0b101, 0b101, 0b101, 0b101, 0b010]),
        "w": (5, [0b10001, 0b10001, 0b10101, 0b10101, 0b01010]),
        "y": (3, [0b101, 0b101, 0b110, 0b100, 0b011]),
    ]
}
