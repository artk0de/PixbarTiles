import PixelClockKit

// The panel's own marks, in the app's pixel language: the user's clock on the
// menu bar is a map of characters and a palette, and so is everything the
// panel draws beside it — the AWTRIX clock, the battery and its bolt, the
// status light, the two footer marks. Emoji and SF Symbols are drawn in
// somebody else's hand; next to the pixel clock they read as borrowed.
//
// Deliberately free of AppKit and SwiftUI, like `UserClock`: maps and
// palettes are data, and data is what the tests pin. `PixelArt` draws them.

enum PanelGlyph {
    typealias Palette = UserClock.Palette

    // MARK: - Devices

    /// The AWTRIX 3 clock: the wide LED bar with its three buttons on top,
    /// showing the time it spends most of its life showing.
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
        "....TT...TTT...TT....",
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

    /// Which drawing stands for a clock: the TC002 is the user's own clock,
    /// the one the menu bar already draws.
    static func map(for model: ClockModel) -> [String] {
        switch model {
        case .ulanziTC002: UserClock.map
        case .awtrix3: awtrix
        }
    }

    /// The device drawing's colours: lit while the clock answers, screen out
    /// while it does not — the menu bar clock's own two palettes.
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
        let lit = reading.map { filledCells(for: $0.percent) } ?? 0
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
    static func inkPalette(_ ink: UInt32) -> Palette { ["G": ink] }
}
