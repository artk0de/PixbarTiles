import PixbarKit

/// What a lamp tile's preview says, since a lamp has no picture.
///
/// The three indicator LEDs sit OUTSIDE the 32×8 matrix, on the case beside
/// it, and nothing in this app knows where. A drawing of them would be a
/// geometry invented here — the same class of lie as a preview that showed
/// glyphs the panel does not have. So the preview of a lamp is a sentence
/// about what that corner is going to do, built from the tile's own config
/// and from nothing else.
///
/// Its own type rather than a format string inside the facade, for the reason
/// `TileRowLine` is one: what a surface says is behaviour, and a string built
/// inline is not somewhere behaviour can be read back from.
enum LampPreviewLine {
    static func text(for lamp: VPNTileConfig?) -> String {
        guard let lamp else {
            return "This tile is a lamp on the clock's corner, not a page."
        }
        let vpn = WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn
        return "\(lamp.slot.lampTitle) lamp · \(colourName(lamp.upColour)) while "
            + "\(vpn) is up, \(down(lamp.whenDown)) when it is not."
    }

    /// The palette's name for a colour, or the hex for one picked off the
    /// wheel. Named where a name exists, because "Electric Lime" is what the
    /// swatch above it says and `#A3FF12` is not.
    private static func colourName(_ hex: String) -> String {
        VPNTilePalette.palette.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name
            ?? hex
    }

    private static func down(_ behaviour: VPNTileConfig.WhenDown) -> String {
        switch behaviour {
        case .off:
            "dark"
        case let .blink(colour):
            "blinking \(colourName(colour))"
        }
    }
}
