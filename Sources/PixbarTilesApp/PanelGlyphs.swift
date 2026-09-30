import PixbarKit

// The panel's own marks, in the app's pixel language: the user's clock in the
// panel's header is a map of characters and a palette, and so is everything
// the panel draws beside it — the AWTRIX clock, the battery and its bolt, the
// status light, the two footer marks. Emoji and SF Symbols are drawn in
// somebody else's hand; next to the pixel clock they read as borrowed.
//
// Deliberately free of AppKit and SwiftUI, like `UserClock`: maps and
// palettes are data, and data is what the tests pin. `PixelArt` draws them.

enum PanelGlyph {
    typealias Palette = UserClock.Palette

    // MARK: - Devices

    /// The AWTRIX 3 clock: the wide LED bar showing the time it spends most of
    /// its life showing. The case is FLAT on top — the TC001 carries no
    /// buttons above its frame, and the three drawn there were wrong.
    ///
    /// On the user's clock's own 21x18 canvas and in its palette keys, so the
    /// two devices sit in a card's leading slot at one size and the approved
    /// dark, light and offline palettes colour both — the screen goes out the
    /// same way on either.
    ///
    ///     F frame   T buttons   M screen margin   S screen
    ///     w digits  b colon
    static let awtrix = [
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".FFFFFFFFFFFFFFFFFFF.",
        "FMMMMMMMMMMMMMMMMMMMF",
        "FMSwSSwwwSSSwwwSwSwMF",
        "FMwwSSSSwSbSSSwSwSwMF",
        "FMSwSSwwwSSSwwwSwwwMF",
        "FMSwSSwSSSbSSSwSSSwMF",
        "FMwwwSwwwSSSwwwSSSwMF",
        "FMMMMMMMMMMMMMMMMMMMF",
        ".FFFFFFFFFFFFFFFFFFF.",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
    ]

    /// The TC002: a taller screen than the TC001's — 52x16 against 32x8 — with
    /// the four page dots its top level draws down the right edge, the first
    /// one lit, and the orange knob it is driven by standing on the LEFT of
    /// the case, where the clock carries it.
    ///
    /// Same canvas and palette keys as the AWTRIX, plus the knob's two:
    ///
    ///     k knob top   K knob side
    static let tc002 = [
        ".....................",
        ".....................",
        "...kkk...............",
        "..kkkkk..............",
        "..KKKKK..............",
        ".FFFFFFFFFFFFFFFFFFF.",
        "FMMMMMMMMMMMMMMMMMMMF",
        "FSSSSSSSSSSSSSSSSSSpF",
        "FSwSSwwwSSSwwwSwSwSSF",
        "FwwSSSSwSbSSSwSwSwSbF",
        "FSwSSwwwSSSwwwSwwwSSF",
        "FSwSSwSSSbSSSwSSSwSbF",
        "FwwwSwwwSSSwwwSSSwSSF",
        "FSSSSSSSSSSSSSSSSSSbF",
        "FMMMMMMMMMMMMMMMMMMMF",
        ".FFFFFFFFFFFFFFFFFFF.",
        ".....................",
        ".....................",
    ]

    /// Which drawing stands for a clock — each as the device it is. The user's
    /// own clock is the app's mark, in the header and on the menu bar.
    static func map(for model: ClockModel) -> [String] {
        switch model {
        case .ulanziTC002: tc002
        case .awtrix3: awtrix
        }
    }

    // MARK: - The pin

    /// A pushpin read side-on: head, narrowed neck, a flange wider than the
    /// head, then the needle. The flange is what makes it a pin — drawn
    /// without one the mark reads as a screw.
    static let pin = [
        "..PPPPP..",
        "..PPPPP..",
        "...PPP...",
        ".PPPPPPP.",
        ".PPPPPPP.",
        "....P....",
        "....P....",
        "....P....",
        "....P....",
    ]

    /// Pinned reads as ON, in the accent the app uses for a live thing.
    static let pinnedTint: UInt32 = 0x4FBAF6

    /// Lit while the panel is pinned, an ordinary control's ink while it is
    /// not. A switch whose two states look alike is a switch nobody can read.
    static func pinPalette(pinned: Bool, ink: UInt32) -> Palette {
        ["P": pinned ? pinnedTint : ink]
    }

    // MARK: - Words set in the clock's own face

    /// The key a set word's lit pixels carry, so one palette entry colours a
    /// whole word.
    static let wordInk: Character = "W"

    /// A word set in one of the kit's bitmap faces, as a row map `PixelArt`
    /// draws.
    ///
    /// The bridge between the two halves of the app's pixel vocabulary: the
    /// kit keeps faces as packed rows (one `UInt8` per row, **bit 0 the
    /// leftmost column** — `PixelCanvas.drawText`'s convention), and the panel
    /// draws `[String]` maps. Nothing is redrawn here: the header's "Clock" is
    /// the same shape the clock itself would put on its panel, so a change to
    /// the face changes the wordmark and the two cannot drift apart.
    ///
    /// One gap column after every letter but the last. A trailing gap is a
    /// word that sits a column left of where it measures.
    static func text(_ text: String, in face: PixelFontFace, lit: Character = wordInk) -> [String] {
        var rows = [String](repeating: "", count: face.height)
        guard text.isEmpty == false else { return rows }
        let last = text.index(before: text.endIndex)
        for index in text.indices {
            let character = text[index]
            // Never nil: a face that cannot spell a mark answers with the
            // substitute, because a skipped glyph is a HOLE in the word.
            let glyph = face.glyph(for: character) ?? []
            let columns = face.columns(of: character)
            for row in rows.indices {
                let bits = row < glyph.count ? glyph[row] : 0
                for column in 0..<columns {
                    rows[row].append(bits & (1 << column) != 0 ? lit : ".")
                }
                if index != last {
                    rows[row].append(contentsOf: String(repeating: ".", count: face.gap))
                }
            }
        }
        return rows
    }

    /// A tile's title: its name and, for an instanced tile, the instance's
    /// name after a spaced hyphen — `GitHub - TeaRAGs` — all upright. An
    /// italic, parenthesised instance was tried and was unreadable at card
    /// size.
    static func title(
        _ name: String, secondary: String?, in face: PixelFontFace, lit: Character = wordInk
    ) -> [String] {
        text(TileTitle(name: name, secondary: secondary).text, in: face, lit: lit)
    }

    /// The knob's orange, lit top and shaded side.
    static let knobTop: UInt32 = 0xFF9F0A
    static let knobSide: UInt32 = 0xC2610A

    /// A device's colours: the shared screen palette, and for the TC002 its
    /// knob — the case's plastic, so it stays yellow when the screen goes out.
    static func devicePalette(for model: ClockModel, dark: Bool, live: Bool) -> Palette {
        var palette = devicePalette(dark: dark, live: live)
        if model == .ulanziTC002 {
            palette["k"] = knobTop
            palette["K"] = knobSide
        }
        return palette
    }

    /// The device drawing's colours: lit while the clock answers, screen out
    /// while it does not — the user's clock's own two palettes.
    static func devicePalette(dark: Bool, live: Bool) -> Palette {
        switch (dark, live) {
        case (true, true): UserClock.darkOnline
        case (true, false): UserClock.darkOffline
        case (false, true): UserClock.lightOnline
        case (false, false): UserClock.lightOffline
        }
    }

    // MARK: - Battery

    /// A rounded cell housing with its terminal, and five cells that light by
    /// fifths of the charge. Cells are 2x2 and a pixel apart, so a lit and an
    /// unlit neighbour never touch.
    ///
    ///     F housing and terminal   1…5 cells, left to right
    static let battery = [
        ".FFFFFFFFFFFFFFFF..",
        "F................F.",
        "F.11.22.33.44.55.FF",
        "F.11.22.33.44.55.FF",
        "F................F.",
        ".FFFFFFFFFFFFFFFF..",
    ]

    /// The charging bolt: two strokes and the bar between them, a pixel taller
    /// than the housing it stands beside so the zigzag has room to read — a
    /// thicker middle at housing height read as a feather.
    static let bolt = [
        "...BB",
        "..BB.",
        ".BB..",
        "BBBBB",
        "..BB.",
        ".BB..",
        "BB...",
    ]

    static let normalTint: UInt32 = 0x4FBAF6     // the clock's blue slider
    static let chargingTint: UInt32 = 0x34C759
    static let lowTint: UInt32 = 0xFF9F0A
    static let criticalTint: UInt32 = 0xFF453A
    static let unknownTint: UInt32 = 0x8E8E93
    /// A remembered charge: the offline clock's grey slider.
    static let staleTint: UInt32 = 0x5C5E66

    /// One cell per fifth of the charge, rounded up — 3% is one sliver, not an
    /// empty housing, because an empty-looking battery that is not empty is
    /// the lie a glance acts on.
    static func filledCells(for percent: Int) -> Int {
        let clamped = min(max(percent, 0), 100)
        return (clamped + 19) / 20
    }

    /// The cells' colour: urgency read off the same two lines the words and
    /// the warning use, and off the direction — a clock filling up at 4% is
    /// not an emergency.
    static func batteryTint(for reading: BatteryReading) -> UInt32 {
        switch reading.direction {
        case .charging: return chargingTint
        case .unknown: return unknownTint
        case .discharging:
            if reading.percent < BatteryLine.critical { return criticalTint }
            if reading.percent < BatteryLine.low { return lowTint }
            return normalTint
        }
    }

    /// The housing in the ink the card is drawn in, the lit cells in the
    /// urgency tint — or greyed when the charge is only remembered — and the
    /// rest left empty. No reading lights nothing.
    static func batteryPalette(for reading: BatteryReading?, ink: UInt32, live: Bool) -> Palette {
        var palette: Palette = ["F": ink]
        // The shown figure, not the raw one: the cells sit beside the number,
        // and a card whose drawing and whose digits disagree is worse than
        // either alone.
        let lit = reading.map { filledCells(for: $0.shownPercent) } ?? 0
        let tint = reading.map { live ? batteryTint(for: $0) : staleTint }
        for (index, key) in "12345".enumerated() {
            palette[key] = index < lit ? tint : .some(nil)
        }
        return palette
    }

    /// The bolt stands beside the housing while the clock is charging and
    /// answering; a remembered charge does not claim a cable it cannot see.
    static func showsBolt(for reading: BatteryReading?, live: Bool) -> Bool {
        live && reading?.direction == .charging
    }

    static let boltPalette: Palette = ["B": chargingTint]

    // MARK: - Status light

    /// A lamp rather than a dot: round and glossed at its top left, which is
    /// what makes a handful of pixels read as a light. Five across — four with
    /// the corners off read as a plus sign.
    ///
    ///     L body   h highlight
    static let led = [
        ".LLL.",
        "LhLLL",
        "LLLLL",
        "LLLLL",
        ".LLL.",
    ]

    static let onlineTint: UInt32 = 0x34C759
    static let checkingTint: UInt32 = 0xFFD60A
    static let offlineTint: UInt32 = 0xFF453A

    static func ledPalette(for dot: PanelModel.ClockDot) -> Palette {
        switch dot {
        case .green: ["L": onlineTint, "h": 0xB4F2C2]
        case .yellow: ["L": checkingTint, "h": 0xFFF3B0]
        case .red: ["L": offlineTint, "h": 0xFFB8B2]
        }
    }

    // MARK: - Footer and card marks

    /// Settings: a solid ring around an open hub, its eight teeth attached —
    /// teeth standing a pixel off the ring read as a sun.
    static let gear = [
        "...GGG...",
        ".G.GGG.G.",
        ".GGGGGGG.",
        "GGG...GGG",
        "GGG...GGG",
        "GGG...GGG",
        ".GGGGGGG.",
        ".G.GGG.G.",
        "...GGG...",
    ]

    /// On the clock now: an almond with a lit pupil, on the card of the tile
    /// whose page the clock is showing.
    static let eyeOpen = [
        "..GGGGG..",
        ".G.....G.",
        "G..GGG..G",
        "G..GGG..G",
        "G..GGG..G",
        ".G.....G.",
        "..GGGGG..",
    ]

    /// Not on the clock: the lower lid alone with its lashes, on every other
    /// tile with a page — click it to bring that page up. Same canvas as the
    /// open eye, so the card does not shift when one opens.
    static let eyeClosed = [
        ".........",
        ".........",
        ".........",
        "G.......G",
        ".GG...GG.",
        "...GGG...",
        ".G..G..G.",
    ]

    /// The open eye is a light ink in either appearance — it is the one lit
    /// thing on the list; the closed eyes are the card chrome's grey.
    static func eyeInk(open: Bool, dark: Bool) -> UInt32 {
        open ? 0xF4F5F8 : PixelInk.secondary(dark: dark)
    }

    /// Remove: a wastebasket read head-on — handle, a lid that overhangs, and
    /// a tapering body with staves down it. The overhang is what makes it a
    /// bin; drawn flush the mark reads as a glass.
    static let bin = [
        "...GGG...",
        "GGGGGGGGG",
        ".........",
        ".GGGGGGG.",
        ".G.G.G.G.",
        ".G.G.G.G.",
        ".G.G.G.G.",
        "..GGGGG..",
        ".........",
    ]

    /// Quit: the power mark, a stem through the gap of an open ring.
    static let power = [
        "....G....",
        "..G.G.G..",
        ".G..G..G.",
        "G...G...G",
        "G.......G",
        "G.......G",
        ".G.....G.",
        "..GGGGG..",
        ".........",
    ]

    /// The one-ink marks: drawn in whatever colour the card's text is.
    // MARK: - A tile's own mark

    /// The key a tile badge's coloured field carries, against `"G"` for the
    /// mark drawn on it.
    static let fieldInk: Character = "B"

    /// A terminal prompt: the Claude and z.ai tiles both report a coding
    /// subscription being spent, and a prompt is what a reader of either has
    /// been looking at all day.
    ///
    /// One mark for the two of them rather than a bar chart for one and a
    /// prompt for the other — they answer the same question about different
    /// accounts, and the account is said by the tile's name beside the mark.
    static let terminalTile = [
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
        "BBGBBBBBBBB",
        "BBBGBBBBBBB",
        "BBBBGBBBBBB",
        "BBBGBBBBBBB",
        "BBGBBBBBBBB",
        "BBBBBBBBBBB",
        "BBBBGGGGGBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
    ]

    /// A cloud. The sun was drawn beside it first and lost at this size: two
    /// shapes in eleven pixels read as one blob.
    static let weatherTile = [
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
        "BBBBGGGBBBB",
        "BBBGGGGGBBB",
        "BBGGGGGGGBB",
        "BGGGGGGGGGB",
        "BGGGGGGGGGB",
        "BBGGGGGGGBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
    ]

    /// A speech bubble: the one tile that SPEAKS.
    static let anecdoteTile = [
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
        "BBGGGGGGGBB",
        "BBGBBBBBGBB",
        "BBGBBBBBGBB",
        "BBGGGGGGGBB",
        "BBBGGBBBBBB",
        "BBBBGBBBBBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
    ]

    /// A padlock, shackle up: the VPN lamp is on when the tunnel is.
    static let vpnTile = [
        "BBBBBBBBBBB",
        "BBBBGGGBBBB",
        "BBBGBBBGBBB",
        "BBBGBBBGBBB",
        "BBGGGGGGGBB",
        "BBGGGGGGGBB",
        "BBGGGBGGGBB",
        "BBGGGGGGGBB",
        "BBGGGGGGGBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
    ]

    /// A star: the GitHub tile counts them, celebrates them, and the shared
    /// table already names it `star`. Five points, the lower two splayed so
    /// the shape is a star at eleven pixels rather than a blob.
    static let githubTile = [
        "BBBBBBBBBBB",
        "BBBBBGBBBBB",
        "BBBBBGBBBBB",
        "BBBBGGGBBBB",
        "BGGGGGGGGGB",
        "BBGGGGGGGBB",
        "BBBGGGGGBBB",
        "BBBGGGGGBBB",
        "BBGGGBGGGBB",
        "BBGBBBBBGBB",
        "BBBBBBBBBBB",
    ]

    /// A question mark, for a tile this app has not heard of. Visibly a tile
    /// rather than a gap, which is what the shared table already decided.
    static let unknownTile = [
        "BBBBBBBBBBB",
        "BBBBGGGBBBB",
        "BBBGBBBGBBB",
        "BBBBBBBGBBB",
        "BBBBBGGBBBB",
        "BBBBBGBBBBB",
        "BBBBBBBBBBB",
        "BBBBBGBBBBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
        "BBBBBBBBBBB",
    ]

    /// The mark a connector's tile wears, in the app's pixel vocabulary.
    ///
    /// Keyed on the connector id, like the shared `TilePresentation` table it
    /// stands beside: what a tile looks like is the TILE's question, and a
    /// running instance may not be in hand when a list is being drawn.
    static func tile(forConnectorId id: String) -> [String] {
        AppTileKinds.wiring(for: id)?.tileGlyph ?? unknownTile
    }

    /// One hue per SHELF rather than per connector.
    ///
    /// The store files tiles on four shelves and the clock's list did not say
    /// so at all — it had a colour per connector, so two Dev tiles sitting
    /// side by side were orange and green and nothing on either card said
    /// what they had in common.
    static func categoryTint(_ category: TileCategory) -> UInt32 {
        switch category {
        case .weather: 0x32ADE6
        case .dev: 0xFF9F0A
        case .system: 0xBF5AF2
        case .network: 0x30D158
        }
    }

    /// A bare question mark, for the marks beside a control whose label
    /// cannot say what it decides. Seven by seven, which is the smallest a
    /// "?" stays legible at while its dot still reads as a dot.
    static let question = [
        ".GGGG..",
        "G....G.",
        ".....G.",
        "...GG..",
        "..G....",
        ".......",
        "..G....",
    ]

    /// The warning sign on a tile card: a triangle with the `!` knocked out
    /// of it. Nine wide so the triangle has a centre column for the `!`, and
    /// eight tall so its stroke and its dot are split by a lit row.
    static let warning = [
        "....T....",
        "...TTT...",
        "...TGT...",
        "..TTGTT..",
        "..TTGTT..",
        ".TTTTTTT.",
        ".TTTGTTT.",
        "TTTTTTTTT",
    ]

    /// The panel's warning yellow — the status LED's "checking" yellow, so a
    /// partial refusal reads as the same caution the panel already says.
    static let warningYellow: UInt32 = checkingTint

    /// The sign's tint by severity — red when the tile does not work, the
    /// warning yellow when a part is withheld. The `!` is knocked out white on
    /// red and near-black on yellow, where white would not read.
    static func warningPalette(_ sign: TileCardTrouble.Sign) -> Palette {
        switch sign {
        case .blocking: ["T": criticalTint, "G": 0xFFFFFF]
        case .partial: ["T": warningYellow, "G": 0x1C1C1E]
        }
    }

    /// The green every surface in this app uses for "this one is up" — the
    /// online LED's. The Add button wears it because adding is the one action
    /// on that surface, not because green is decorative.
    static let addTint: UInt32 = 0x30D158

    /// The Add green darkened: a store card whose tile is already on the
    /// clock. The same family as the button it replaces, so it reads as the
    /// state after the act, not as another act.
    static let addedTint: UInt32 = 0x1E7A3A

    // MARK: - The store's shelves

    /// All: four blocks, the whole store.
    static let shelfAll = [
        ".........",
        ".GGG.GGG.",
        ".GGG.GGG.",
        ".GGG.GGG.",
        ".........",
        ".GGG.GGG.",
        ".GGG.GGG.",
        ".GGG.GGG.",
        ".........",
    ]

    /// Weather: a sun. The tile badge on the shelf's cards is a cloud, so
    /// the shelf takes the other half of the sky.
    static let shelfWeather = [
        "....G....",
        ".G.....G.",
        "...GGG...",
        "..GGGGG..",
        "G.GGGGG.G",
        "..GGGGG..",
        "...GGG...",
        ".G.....G.",
        "....G....",
    ]

    /// System: a monitor on its stand.
    static let shelfSystem = [
        "GGGGGGGGG",
        "G.......G",
        "G.......G",
        "G.......G",
        "G.......G",
        "GGGGGGGGG",
        "....G....",
        "..GGGGG..",
        ".........",
    ]

    /// Dev: a pair of braces.
    static let shelfDev = [
        ".........",
        ".GG...GG.",
        ".G.....G.",
        ".G.....G.",
        "G.......G",
        ".G.....G.",
        ".G.....G.",
        ".GG...GG.",
        ".........",
    ]

    /// Network: two arcs over a point — a signal.
    static let shelfNetwork = [
        ".........",
        "..GGGGG..",
        ".G.....G.",
        "G..GGG..G",
        "..G...G..",
        ".........",
        "....G....",
        "...GGG...",
        "....G....",
    ]

    /// The mark a shelf row wears in the store's sidebar; nil is All.
    static func shelfMark(_ category: TileCategory?) -> [String] {
        switch category {
        case nil: shelfAll
        case .weather: shelfWeather
        case .system: shelfSystem
        case .dev: shelfDev
        case .network: shelfNetwork
        }
    }

    /// The neutral All wears: every shelf's, so none of theirs.
    static let allShelvesTint: UInt32 = 0x8E8E93

    /// A shelf row's colour — the tint its cards' badges already wear, so a
    /// row and the cards it files cannot disagree; nil is All.
    static func shelfTint(_ category: TileCategory?) -> UInt32 {
        category.map(categoryTint) ?? allShelvesTint
    }

    /// A badge: the shelf's colour as the field, the mark knocked out of it in
    /// white. White rather than the card's ink, because the field is a colour
    /// and a mark in grey on it is a mark nobody sees.
    static func tilePalette(_ category: TileCategory) -> Palette {
        ["B": categoryTint(category), "G": 0xFFFFFF]
    }

    static func inkPalette(_ ink: UInt32) -> Palette { ["G": ink] }
}
