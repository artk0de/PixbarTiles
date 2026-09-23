/// One bitmap face: a fixed cell, the gap that follows it, and the shapes.
///
/// A value rather than a namespace, because the kit now carries TWO faces and
/// every measurement — how wide a line is, where a right-aligned figure
/// starts — has to be asked OF the face that will draw it. A face that
/// measured with one cell and drew with another is how text walks off the
/// edge of a panel.
///
/// Rows are top-first, one byte per row, and only the low `width` bits are
/// read: **bit 0 is the leftmost column**. That is `PixelCanvas.drawText`'s
/// own convention (`bits & (1 << column)` painted at `cursor + column`), and
/// both tables are written to it.
///
/// A face may be PROPORTIONAL: a glyph listed in `glyphWidths` takes that many
/// columns instead of the cell's, and the cursor steps past exactly those
/// columns plus the gap. The fixed faces list none, so everything they measure
/// and draw is what it was before a face could be narrower than its cell.
public struct PixelFontFace: Sendable {
    /// Columns in the cell — the widest a glyph is unless it names its own.
    public let width: Int
    /// Rows in the cell.
    public let height: Int
    /// Columns left blank after each glyph.
    public let gap: Int
    private let glyphs: [Character: [UInt8]]
    private let glyphWidths: [Character: Int]

    /// What one character costs the cursor in a fixed face: the cell plus its
    /// gap. A proportional face answers per character — `advance(for:)`.
    public var advance: Int { width + gap }

    init(
        width: Int, height: Int, gap: Int, glyphs: [Character: [UInt8]],
        glyphWidths: [Character: Int] = [:]
    ) {
        self.width = width
        self.height = height
        self.gap = gap
        self.glyphs = glyphs
        self.glyphWidths = glyphWidths
    }

    /// The columns `character` draws in: its own width when the face names
    /// one, the cell's otherwise — and the SUBSTITUTE's for a mark the face
    /// cannot spell, because the substitute is what gets drawn there.
    public func columns(of character: Character) -> Int {
        let drawn = covers(character) ? character : PixelFont.substitute
        return glyphWidths[drawn] ?? width
    }

    /// What `character` costs the cursor: its columns plus the gap.
    public func advance(for character: Character) -> Int {
        columns(of: character) + gap
    }

    /// Whether this face has a shape of its own for `character` — as opposed
    /// to answering with the substitute.
    public func covers(_ character: Character) -> Bool {
        glyphs[character] != nil
    }

    /// The shape to paint for `character`, and never nil.
    ///
    /// The nil this used to return is the whole defect: `drawText` skipped the
    /// character and advanced anyway, so a mark the table did not carry came
    /// out as a HOLE in the middle of a word — `H45%` lost its H, `feels 12°`
    /// lost every letter. A face that cannot spell a mark now says so with the
    /// substitute, which a reader can see and a test can assert. A gap on the
    /// panel means a space and nothing else.
    public func glyph(for character: Character) -> [UInt8]? {
        glyphs[character] ?? glyphs[PixelFont.substitute]
    }

    /// The columns `text` occupies at `scale`: one advance per character, the
    /// trailing gap not counted — nothing is drawn in it, and a face placing
    /// text from the right edge would otherwise sit one gap short.
    public func width(of text: String, scale: Int) -> Int {
        guard text.isEmpty == false else { return 0 }
        return text.reduce(0) { $0 + advance(for: $1) } * scale - gap * scale
    }
}

public extension PixelFontFace {
    /// The two shipped faces, reachable by the leading dot wherever the type
    /// is already known — `drawText(…, font: .standard)`. They forward to
    /// `PixelFont`'s own, so there is one definition and two spellings of it.
    static var tiny: PixelFontFace { PixelFont.tiny }
    static var standard: PixelFontFace { PixelFont.standard }
    static var proportional: PixelFontFace { PixelFont.proportional }
}

/// The faces the kit draws with.
///
/// Two of them, and the split is the panel's, not a preference. The TC002's
/// usage page stacks three bands into sixteen rows, which leaves five rows a
/// band and settles the small cell at 3×5. Anything with room — a headline
/// figure, an AWTRIX line, a word in Russian — draws in the X11 5×7 face,
/// which is the one the live demo proved on 2026-09-21 and the only one with
/// a Cyrillic alphabet.
public enum PixelFont {
    /// What a face draws for a mark it has no shape for. Printable, so it
    /// survives `UlanziScene`'s own ASCII filter on the way to the device.
    public static let substitute: Character = "?"

    /// The 3×5 cell the three-band usage page is built around.
    public static let tiny = PixelFontFace(width: 3, height: 5, gap: 1, glyphs: tinyGlyphs)

    /// The X11 "Misc Fixed" 5×7 face — every printable ASCII mark plus the
    /// Cyrillic alphabet, generated from the BDF by `Scripts/MakeFontTable.py`.
    public static let standard = PixelFontFace(width: 5, height: 7, gap: 1, glyphs: x11Glyphs)

    /// The shared usage face's five-row proportional face — the approved
    /// design's own glyph table, see `ProportionalGlyphs.swift`.
    public static let proportional = PixelFontFace(
        width: 5, height: 5, gap: 1,
        glyphs: proportionalGlyphs.mapValues(\.rows),
        glyphWidths: proportionalGlyphs.mapValues(\.width)
    )

    /// The bare spelling every shipped face still calls, kept pointing at the
    /// small cell so no face moved when the second one arrived.
    public static func glyph(for character: Character) -> [UInt8]? {
        tiny.glyph(for: character)
    }

    /// The columns a line occupies at `scale` in the small cell. This is the
    /// width `PixelCanvas.drawText` advances by default, so a face placing
    /// text from the right edge cannot disagree with where the glyphs land.
    public static func width(of text: String, scale: Int) -> Int {
        tiny.width(of: text, scale: scale)
    }
}
