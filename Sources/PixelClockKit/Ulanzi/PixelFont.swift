/// 3×5 pixel font for the glyphs the TC002 faces actually draw (D12): digits
/// 0–9, `-`, `%`, `°`, space — and nothing more. No speculative alphabet; a
/// time face adds `:` when one exists.
///
/// Rows are top-first, one byte per row, low 3 bits = left-to-right (bit 0 is
/// the leftmost column).
public enum PixelFont {
    public static func glyph(for character: Character) -> [UInt8]? {
        glyphs[character]
    }

    private static let glyphs: [Character: [UInt8]] = [
        "0": [0b111, 0b101, 0b101, 0b101, 0b111],
        "1": [0b011, 0b010, 0b010, 0b010, 0b111],
        "2": [0b111, 0b100, 0b111, 0b001, 0b111],
        "3": [0b111, 0b001, 0b111, 0b001, 0b111],
        "4": [0b101, 0b101, 0b111, 0b001, 0b001],
        "5": [0b111, 0b001, 0b111, 0b100, 0b111],
        "6": [0b111, 0b100, 0b111, 0b101, 0b111],
        "7": [0b111, 0b001, 0b001, 0b001, 0b001],
        "8": [0b111, 0b101, 0b111, 0b101, 0b111],
        "9": [0b111, 0b101, 0b111, 0b001, 0b111],
        "-": [0b000, 0b000, 0b111, 0b000, 0b000],
        "%": [0b001, 0b100, 0b010, 0b001, 0b100],
        "°": [0b011, 0b011, 0b000, 0b000, 0b000],
        " ": [0b000, 0b000, 0b000, 0b000, 0b000],
    ]
}
