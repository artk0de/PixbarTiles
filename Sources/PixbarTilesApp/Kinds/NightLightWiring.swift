import Foundation
import PixbarKit
import SwiftUI

struct NightLightWiring: TileKindWiring {
    typealias Kind = NightLightKind
    var tileGlyph: [String] { PanelGlyph.nightLightTile }
}
