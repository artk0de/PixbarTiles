import Foundation
import PixelClockKit

/// Builds the per-clock registry: every connector as a factory over its own
/// tile record.
///
/// Out of `AppModel.live` so the composition root stays a list of
/// collaborators, and so a connector added later is wired here rather than
/// growing that function. A factory reads its tile's settings off the
/// `TileRecord` it is handed — the schedule hands it the stored record on
/// every run, so a choice made in a tile's detail reaches the next poll — where
/// the closures this replaced searched the tile store for the first record of
/// their connector on the clock, which could only ever find one tile of it.
///
/// What remembers across runs is built once per clock, outside the factories:
/// the anecdote connector (one queue — see `AppModel.anecdoteWiring`), the
/// clock's stored place, and the Claude status-line reporter, which keeps the
/// last window it saw.
struct ConnectorFactories {
    private let transport: any Transport
    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    private let weather: OpenMeteoSource
    private let anecdotes: any Connector

    init(
        transport: any Transport, defaults: UserDefaults, secrets: any SecretStoring,
        weather: OpenMeteoSource, anecdotes: any Connector
    ) {
        self.transport = transport
        self.defaults = defaults
        self.secrets = secrets
        self.weather = weather
        self.anecdotes = anecdotes
    }

    // A registry per clock, so each clock's weather reads its own tile's
    // place through the one shared source — which caches per place. The
    // same registry for both models: the connectors are the app's, the
    // faces are the clock's.
    @MainActor
    func registry(for clock: ClockRecord) -> ConnectorRegistry {
        let registry = ConnectorRegistry()
        registry.register(anecdotes)
        let place = StoredLocation(defaults: defaults, clockId: clock.id)
        let weather = self.weather
        // The weather tile's own settings, read off the record that holds
        // them — a change in the tile's window reaches the next poll,
        // exactly the way the place does. The place stays what a config
        // without one falls back to.
        registry.register(
            factory: { tile in
                WeatherConnector(
                    source: weather,
                    location: { place.current },
                    config: { tile.config?.weatherConfig ?? WeatherTileConfig(place: place.current) }
                )
            },
            for: WeatherConnector.appName
        )
        // Both coding-subscription tiles read their parameters off their own
        // record at every draw, so a picker moved in the tile's window
        // reaches the next poll rather than the next launch — exactly the
        // way the weather's place does. The tiles take the SAME parameters:
        // what differs between them is how each reaches its account.
        let reporter = StatusLineClaudeUsageReporter(document: ClaudeCodePaths.document)
        registry.register(
            factory: { tile in
                ClaudeUsageConnector(
                    reporter: reporter,
                    parameters: { tile.config?.parameters ?? .standard }
                )
            },
            for: ClaudeUsageConnector.id
        )
        // The key is looked up at every read, never held: a key pasted
        // into the tile's detail is on its way to the service at the next
        // poll, and one removed from it is gone just as fast.
        let transport = self.transport
        let secrets = self.secrets
        registry.register(
            factory: { tile in
                ZaiUsageConnector(
                    source: ZaiUsageAPI(
                        transport: transport,
                        key: { secrets.secret(for: .tile(tile.key)) }
                    ),
                    parameters: { tile.config?.parameters ?? .standard }
                )
            },
            for: ZaiUsageConnector.connectorId
        )
        return registry
    }
}
