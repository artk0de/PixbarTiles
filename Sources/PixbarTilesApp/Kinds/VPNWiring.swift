import Foundation
import PixbarKit
import SwiftUI

/// The VPN lamp is no connector: the lamp controller drives it, so it
/// registers nothing on a clock.
struct VPNWiring: TileKindWiring {
    typealias Kind = VPNKind
    var tileGlyph: [String] { PanelGlyph.vpnTile }

    func block(_ context: TileBlockContext<VPNTileConfig>) -> some View {
        VPNLampSettings(key: context.key, lamp: context.parameters, settings: context.settings)
    }
}

/// A lamp tile's settings: which VPN, which corner, which colour, and what
/// "down" looks like.
struct VPNLampSettings: View {
    let key: TileKey
    let lamp: VPNTileConfig?
    let settings: TileSettingsModel

    /// The lamp tile's block: which VPN, which corner, which colour, and
    /// what "down" looks like.
    ///
    /// The block itself has existed since the tile did, with its own tests,
    /// and nothing ever built one — so a VPN tile was the one tile in the
    /// app whose settings window had no settings in it.
    var body: some View {
        if let lamp {
            VPNTileBlock(
                presets: WatchedVPN.catalogue.map(\.displayName),
                preset: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn,
                slots: IndicatorSlot.allCases.map(\.lampTitle),
                slot: lamp.slot.lampTitle,
                colour: Color(hex: lamp.upColour),
                downBehaviour: lamp.whenDown == .off ? .off : .blink,
                onPreset: { name in
                    guard let chosen = WatchedVPN.catalogue.first(where: { $0.displayName == name })
                    else { return }
                    settings.changeLampVPN(to: chosen.id)
                },
                onSlot: { title in
                    guard let chosen = IndicatorSlot.allCases.first(where: { $0.lampTitle == title })
                    else { return }
                    saveLamp(lamp, on: key) { $0.slot = chosen }
                },
                onColour: { colour in
                    saveLamp(lamp, on: key) { $0.upColour = colour.hexString }
                },
                onDownBehaviour: { behaviour in
                    saveLamp(lamp, on: key) {
                        switch behaviour {
                        case .off:
                            $0.whenDown = .off
                        case .blink:
                            // Its own colour, kept when there already is one:
                            // a lamp toggled off and back on must not forget
                            // what it blinked.
                            if case .blink = $0.whenDown { break }
                            $0.whenDown = .blink(VPNTilePalette.alarm)
                        }
                    }
                }
            )
        } else {
            // A lamp tile with no lamp on it — a record written before the
            // config existed, or one whose config failed to decode. Says so
            // instead of drawing four pickers over nothing.
            Text("This tile has no lamp settings. Remove it and add it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveLamp(
        _ lamp: VPNTileConfig, on key: TileKey, _ change: (inout VPNTileConfig) -> Void
    ) {
        guard let stored = settings.storedPolicy(of: key) else { return }
        var edited = lamp
        change(&edited)
        settings.save(policy: stored, config: .vpn(edited))
    }
}
