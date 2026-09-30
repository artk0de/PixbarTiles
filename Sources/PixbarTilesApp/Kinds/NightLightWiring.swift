import Foundation
import PixbarKit
import SwiftUI

struct NightLightWiring: TileKindWiring {
    typealias Kind = NightLightKind
    var tileGlyph: [String] { PanelGlyph.nightLightTile }

    /// The scene is drawn off the tile's own record at every run, so a
    /// setting changed in the tile's window reaches the next push.
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {
        let canNameSleep = env.canNameSleep
        registry.register(
            factory: { tile in
                NightLightConnector(
                    config: { tile.config?.nightLightConfig ?? NightLightTileConfig() },
                    canNameSleep: canNameSleep
                )
            },
            for: Kind.id
        )
    }

    /// The instance a tile added from the store takes its policy from: Sleep
    /// when this Mac can name it.
    func namingInstance(_ naming: TileNaming) -> (any Connector)? {
        NightLightConnector(config: { NightLightTileConfig() }, canNameSleep: naming.canNameSleep)
    }

    /// The night starts: the scene is put on its page, then the clock is
    /// switched to it — the one tile the app brings to the front by itself,
    /// because at Sleep or at 22:00 nobody is turning the knob.
    @MainActor func arrived(_ key: TileKey, _ parameters: NightLightTileConfig?, _ actions: TileArrivalActions) {
        guard (parameters ?? NightLightTileConfig()).autoShow else { return }
        actions.run(key)
        actions.show(key)
    }

    /// The night ends: the page goes idle and the clock is handed to the
    /// morning tile. The TC002 cannot say what it showed before, so "going
    /// back" means going to a tile somebody chose, or the first in order.
    @MainActor func left(_ key: TileKey, _ parameters: NightLightTileConfig?, _ actions: TileArrivalActions) {
        let settings = parameters ?? NightLightTileConfig()
        guard settings.autoShow else { return }
        actions.idle(key)
        if let morning = actions.morningTile(key.clockId, settings.morningTileId, key) {
            actions.show(morning)
        }
    }
}
