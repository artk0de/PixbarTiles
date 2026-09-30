import Foundation
import PixbarKit

struct WeatherWiring: TileKindWiring {
    typealias Kind = WeatherKind
    var tileGlyph: [String] { PanelGlyph.weatherTile }
    var namesItsOwnRefresh: Bool { true }

    /// Each clock's weather reads its own tile's place through the one shared
    /// source. The tile's own settings are read off the record that holds
    /// them — a change in the tile's window reaches the next poll, exactly the
    /// way the place does. The place stays what a config without one falls
    /// back to.
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {
        let place = StoredLocation(defaults: env.defaults, clockId: clock.id)
        let weather = env.weather
        registry.register(
            factory: { tile in
                WeatherConnector(
                    source: weather,
                    location: { place.current },
                    config: { tile.config?.weatherConfig ?? WeatherTileConfig(place: place.current) }
                )
            },
            for: Kind.id
        )
    }
}
