import Foundation
import PixbarKit

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
/// What remembers across runs is built once per clock, outside the factories,
/// by each kind's wiring (`AppTileKinds`): this type only hands every wiring
/// the app's shared sources and the clock.
struct ConnectorFactories {
    private let tileEnvironment: TileEnvironment

    init(
        transport: any Transport, defaults: UserDefaults, secrets: any SecretStoring,
        weather: OpenMeteoSource, anecdotes: any Connector,
        claudeReporter: @escaping @Sendable () -> any ClaudeUsageReporting = {
            StatusLineClaudeUsageReporter(document: ClaudeCodePaths.document)
        }
    ) {
        tileEnvironment = TileEnvironment(
            transport: transport, defaults: defaults, secrets: secrets,
            weather: weather, anecdotes: anecdotes, claudeReporter: claudeReporter
        )
    }

    // A registry per clock, so each clock's weather reads its own tile's
    // place through the one shared source — which caches per place. The
    // same registry for both models: the connectors are the app's, the
    // faces are the clock's.
    @MainActor
    func registry(for clock: ClockRecord) -> ConnectorRegistry {
        let registry = ConnectorRegistry()
        for wiring in AppTileKinds.all {
            wiring.register(into: registry, for: clock, tileEnvironment)
        }
        return registry
    }

    /// The instances the app-wide registry holds only so the store can name
    /// them and the panel can ask what they are — in the order they are
    /// offered. No clock produces through one: each clock's session builds
    /// its own from the tile's record, so these carry no key, no token and no
    /// repository.
    static func namingInstances(transport: any Transport) -> [any Connector] {
        AppTileKinds.all.compactMap { $0.namingInstance(transport: transport) }
    }
}
