import Foundation
import PixbarKit

/// The VPN lamp is no connector: the lamp controller drives it, so it
/// registers nothing on a clock.
struct VPNWiring: TileKindWiring {
    typealias Kind = VPNKind
    var tileGlyph: [String] { PanelGlyph.vpnTile }
}
