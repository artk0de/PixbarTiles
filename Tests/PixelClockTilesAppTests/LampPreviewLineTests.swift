import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// A lamp has no picture, so its preview is a sentence. Tested as one: the
// words are what the reader gets instead of a face, and a sentence built
// inline in the facade is not somewhere behaviour can be read back from.

@Suite struct LampPreviewLineTests {
    @Test func aSteadyLampSaysItsCornerItsColourAndItsVPN() {
        let line = LampPreviewLine.text(
            for: VPNTileConfig(
                vpn: WatchedVPN.pritunl.id, slot: .topRight,
                upColour: "#A3FF12", whenDown: .off
            )
        )
        #expect(line == "Top right lamp · Electric Lime while Pritunl is up, dark when it is not.")
    }

    @Test func aBlinkingLampSaysWhatItBlinks() {
        let line = LampPreviewLine.text(
            for: VPNTileConfig(
                vpn: WatchedVPN.amnezia.id, slot: .bottomRight,
                upColour: "#00F0FF", whenDown: .blink("#FF1744")
            )
        )
        #expect(
            line == "Bottom right lamp · Cyber Cyan while Amnezia is up, "
                + "blinking Alarm Red when it is not."
        )
    }

    // A colour picked off the wheel has no name in the palette, and inventing
    // one would be worse than showing the hex the config actually stores.
    @Test func aColourOffThePaletteIsSaidAsItsHex() {
        let line = LampPreviewLine.text(
            for: VPNTileConfig(
                vpn: WatchedVPN.pritunl.id, slot: .middleRight,
                upColour: "#123456", whenDown: .off
            )
        )
        #expect(line.contains("#123456"))
        #expect(line.hasPrefix("Middle right lamp · #123456 while Pritunl is up"))
    }

    // The palette writes its hexes in upper case and a picker may hand back
    // either, so the lookup must not turn a named colour into a raw hex on a
    // difference nobody can see.
    @Test func aPaletteColourIsNamedWhateverCaseItIsWrittenIn() {
        let line = LampPreviewLine.text(
            for: VPNTileConfig(
                vpn: WatchedVPN.pritunl.id, slot: .topRight,
                upColour: "#a3ff12", whenDown: .off
            )
        )
        #expect(line.contains("Electric Lime"))
    }

    // A lamp tile with no config on it — the record the migration never
    // wrote, or one whose config failed to decode. The old sentence, which is
    // still the truthful thing to say when there is nothing to say about it.
    @Test func aLampWithNoConfigStillSaysWhatKindOfTileItIs() {
        #expect(
            LampPreviewLine.text(for: nil)
                == "This tile is a lamp on the clock's corner, not a page."
        )
    }
}
