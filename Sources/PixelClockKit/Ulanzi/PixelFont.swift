/// 3×5 pixel font for the glyphs the TC002 faces actually draw (D12): digits
/// 0–9, `-`, `%`, `°`, space, and the letters the usage rows' labels draw —
/// nothing more. No speculative alphabet; a time face adds `:` when one
/// exists, and a usage label adds its letters when one is drawn.
///
/// Rows are top-first, one byte per row, low 3 bits = left-to-right (bit 0 is
/// the leftmost column).
public enum PixelFont {
    public static func glyph(for character: Character) -> [UInt8]? {
        glyphs[character]
    }

    /// The columns a line occupies at `scale`: a 3-column glyph plus the gap
    /// after it, per character, the trailing gap not counted. This is the
    /// width `PixelCanvas.drawText` advances, so a face placing text from the
    /// right edge cannot disagree with where the glyphs land.
    public static func width(of text: String, scale: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.unicodeScalars.count * 4 * scale - scale
    }

    private static let glyphs: [Character: [UInt8]] = [
        "0": [0b111, 0b101, 0b101, 0b101, 0b111],
        "1": [0b011, 0b010, 0b010, 0b010, 0b111],
        "2": [0b111, 0b100, 0b111, 0b001, 0b111],
        "3": [0b111, 0b001, 0b111, 0b001, 0b111],
        "4": [0b101, 0b101, 0b111, 0b001, 0b001],
        "5": [0b111, 0b001, 0b111, 0b100, 0b111],
        "6": [0b111, 0b100, 0b111, 0b101, 0b111],
        "7": [0b111, 0b100, 0b100, 0b100, 0b100],
        "8": [0b111, 0b101, 0b111, 0b101, 0b111],
        "9": [0b111, 0b101, 0b111, 0b001, 0b111],
        "-": [0b000, 0b000, 0b111, 0b000, 0b000],
        "%": [0b001, 0b100, 0b010, 0b001, 0b100],
        "°": [0b011, 0b011, 0b000, 0b000, 0b000],
        " ": [0b000, 0b000, 0b000, 0b000, 0b000],
        "A": [0b010, 0b101, 0b111, 0b101, 0b101],
        "C": [0b011, 0b100, 0b100, 0b100, 0b011],
        "D": [0b011, 0b101, 0b101, 0b101, 0b011],
        "E": [0b111, 0b001, 0b111, 0b001, 0b111],
        "K": [0b101, 0b011, 0b001, 0b011, 0b101],
        "M": [0b101, 0b111, 0b111, 0b101, 0b101],
        "P": [0b111, 0b101, 0b111, 0b001, 0b001],
        "S": [0b011, 0b100, 0b010, 0b001, 0b110],
        "W": [0b101, 0b101, 0b101, 0b101, 0b010],
        "Y": [0b101, 0b101, 0b010, 0b010, 0b010],
    ]
}
