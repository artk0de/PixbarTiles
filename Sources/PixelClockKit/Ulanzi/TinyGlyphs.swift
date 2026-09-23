/// Every printable ASCII character as a 3×5 glyph — the table that closes
/// the holes `PixelCanvas.drawText` leaves when a face draws a character the
/// 24-glyph `PixelFont` table never had (`H45%`, `feels 12°`). A skipped
/// character still advances the cursor, so the gap it leaves is a hole in the
/// word, not a shorter word — every printable byte needs a shape.
///
/// Same convention as `PixelFont`: 5 bytes, one per row, top row first, and
/// only the low 3 bits of each row are read — **bit 0 is the leftmost**
/// column, bit 2 the rightmost, matching `drawText`'s `bits & (1 << column)`
/// paint at `cursor + column`. Written binary so each literal is the glyph's
/// own shape mirrored: `0b011` is the left two columns.
///
/// The digits, `-`, `%`, `°`, space and the capitals A C D E K M P S W Y keep
/// `PixelFont`'s bytes verbatim — tests pin the pixels those draw, so their
/// shapes are settled and not ours to improve. Everything else is authored
/// for a 1:1 LED matrix: lowercase sits at a four-row x-height (rows 1–4),
/// ascenders reach row 0, and `g j p q y` spend row 4 on a descender.
extension PixelFont {
    static let tinyGlyphs: [Character: [UInt8]] = [
        // Space and punctuation before the digits.
        " ": [0b000, 0b000, 0b000, 0b000, 0b000],
        "!": [0b010, 0b010, 0b010, 0b000, 0b010],
        "\"": [0b101, 0b101, 0b000, 0b000, 0b000],
        "#": [0b101, 0b111, 0b101, 0b111, 0b101],
        "$": [0b110, 0b011, 0b010, 0b110, 0b011],
        "%": [0b001, 0b100, 0b010, 0b001, 0b100],
        "&": [0b010, 0b101, 0b010, 0b101, 0b110],
        "'": [0b010, 0b010, 0b000, 0b000, 0b000],
        "(": [0b100, 0b010, 0b010, 0b010, 0b100],
        ")": [0b001, 0b010, 0b010, 0b010, 0b001],
        "*": [0b000, 0b101, 0b010, 0b101, 0b000],
        "+": [0b000, 0b010, 0b111, 0b010, 0b000],
        ",": [0b000, 0b000, 0b000, 0b010, 0b001],
        "-": [0b000, 0b000, 0b111, 0b000, 0b000],
        ".": [0b000, 0b000, 0b000, 0b000, 0b010],
        "/": [0b100, 0b100, 0b010, 0b001, 0b001],
        // Digits — pinned patterns.
        "0": [0b111, 0b101, 0b101, 0b101, 0b111],
        "1": [0b011, 0b010, 0b010, 0b010, 0b111],
        "2": [0b111, 0b100, 0b111, 0b001, 0b111],
        // Mirrored in the table this one inherited: written as if bit 2 were
        // the left column, these six came out backwards on the panel. `3` was
        // byte-identical to `E`, `6` drew a 9 and `9` drew a 6 — a percentage
        // on the clock could not be read. Corrected against the 5×7 face,
        // which the BDF gets right.
        "3": [0b111, 0b100, 0b111, 0b100, 0b111],
        "4": [0b101, 0b101, 0b111, 0b100, 0b100],
        "5": [0b111, 0b001, 0b111, 0b100, 0b111],
        "6": [0b111, 0b001, 0b111, 0b101, 0b111],
        "7": [0b111, 0b100, 0b100, 0b100, 0b100],
        "8": [0b111, 0b101, 0b111, 0b101, 0b111],
        "9": [0b111, 0b101, 0b111, 0b100, 0b111],
        // Punctuation between the digits and the capitals.
        ":": [0b000, 0b010, 0b000, 0b010, 0b000],
        ";": [0b000, 0b010, 0b000, 0b010, 0b001],
        "<": [0b100, 0b010, 0b001, 0b010, 0b100],
        "=": [0b000, 0b111, 0b000, 0b111, 0b000],
        ">": [0b001, 0b010, 0b100, 0b010, 0b001],
        "?": [0b111, 0b100, 0b010, 0b000, 0b010],
        "@": [0b111, 0b101, 0b111, 0b001, 0b110],
        // Capitals.
        "A": [0b010, 0b101, 0b111, 0b101, 0b101],
        "B": [0b011, 0b101, 0b011, 0b101, 0b011],
        "C": [0b110, 0b001, 0b001, 0b001, 0b110],
        "D": [0b011, 0b101, 0b101, 0b101, 0b011],
        "E": [0b111, 0b001, 0b111, 0b001, 0b111],
        "F": [0b111, 0b001, 0b111, 0b001, 0b001],
        "G": [0b111, 0b001, 0b101, 0b101, 0b111],
        "H": [0b101, 0b101, 0b111, 0b101, 0b101],
        "I": [0b111, 0b010, 0b010, 0b010, 0b111],
        "J": [0b100, 0b100, 0b100, 0b101, 0b010],
        "K": [0b101, 0b011, 0b001, 0b011, 0b101],
        "L": [0b001, 0b001, 0b001, 0b001, 0b111],
        "M": [0b101, 0b111, 0b111, 0b101, 0b101],
        "N": [0b101, 0b111, 0b101, 0b101, 0b101],
        "O": [0b010, 0b101, 0b101, 0b101, 0b010],
        "P": [0b111, 0b101, 0b111, 0b001, 0b001],
        "Q": [0b010, 0b101, 0b101, 0b101, 0b110],
        "R": [0b011, 0b101, 0b011, 0b101, 0b101],
        "S": [0b110, 0b001, 0b010, 0b100, 0b011],
        "T": [0b111, 0b010, 0b010, 0b010, 0b010],
        "U": [0b101, 0b101, 0b101, 0b101, 0b111],
        "V": [0b101, 0b101, 0b101, 0b010, 0b010],
        "W": [0b101, 0b101, 0b101, 0b101, 0b010],
        "X": [0b101, 0b101, 0b010, 0b101, 0b101],
        "Y": [0b101, 0b101, 0b010, 0b010, 0b010],
        "Z": [0b111, 0b100, 0b010, 0b001, 0b111],
        // Brackets and marks between the cases.
        "[": [0b110, 0b010, 0b010, 0b010, 0b110],
        "\\": [0b001, 0b001, 0b010, 0b100, 0b100],
        "]": [0b011, 0b010, 0b010, 0b010, 0b011],
        "^": [0b010, 0b101, 0b000, 0b000, 0b000],
        "_": [0b000, 0b000, 0b000, 0b000, 0b111],
        "`": [0b001, 0b010, 0b000, 0b000, 0b000],
        // Lowercase.
        "a": [0b000, 0b111, 0b100, 0b111, 0b111],
        "b": [0b001, 0b001, 0b111, 0b101, 0b111],
        "c": [0b000, 0b111, 0b001, 0b001, 0b111],
        "d": [0b100, 0b100, 0b111, 0b101, 0b111],
        "e": [0b000, 0b111, 0b111, 0b001, 0b111],
        "f": [0b110, 0b010, 0b111, 0b010, 0b010],
        "g": [0b000, 0b111, 0b101, 0b111, 0b011],
        "h": [0b001, 0b001, 0b111, 0b101, 0b101],
        "i": [0b010, 0b000, 0b010, 0b010, 0b010],
        "j": [0b100, 0b000, 0b100, 0b100, 0b011],
        "k": [0b001, 0b001, 0b101, 0b011, 0b101],
        "l": [0b011, 0b010, 0b010, 0b010, 0b110],
        "m": [0b000, 0b111, 0b111, 0b101, 0b101],
        "n": [0b000, 0b011, 0b101, 0b101, 0b101],
        "o": [0b000, 0b111, 0b101, 0b101, 0b111],
        "p": [0b000, 0b111, 0b101, 0b111, 0b001],
        "q": [0b000, 0b111, 0b101, 0b111, 0b100],
        "r": [0b000, 0b011, 0b101, 0b001, 0b001],
        "s": [0b000, 0b111, 0b001, 0b100, 0b111],
        "t": [0b010, 0b111, 0b010, 0b010, 0b110],
        "u": [0b000, 0b101, 0b101, 0b101, 0b111],
        "v": [0b000, 0b101, 0b101, 0b101, 0b010],
        "w": [0b000, 0b101, 0b101, 0b111, 0b010],
        "x": [0b000, 0b101, 0b010, 0b010, 0b101],
        "y": [0b000, 0b101, 0b101, 0b110, 0b011],
        "z": [0b000, 0b111, 0b100, 0b001, 0b111],
        // Braces and the tilde.
        "{": [0b110, 0b010, 0b011, 0b010, 0b110],
        "|": [0b010, 0b010, 0b010, 0b010, 0b010],
        "}": [0b011, 0b010, 0b110, 0b010, 0b011],
        "~": [0b000, 0b000, 0b110, 0b011, 0b000],
        // The degree sign the weather faces draw.
        "°": [0b011, 0b011, 0b000, 0b000, 0b000],
    ]
}
