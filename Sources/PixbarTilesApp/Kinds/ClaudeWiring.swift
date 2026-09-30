import Foundation
import PixbarKit

struct ClaudeWiring: TileKindWiring {
    typealias Kind = ClaudeKind
    var tileGlyph: [String] { PanelGlyph.terminalTile }
    var namesItsOwnRefresh: Bool { true }

    /// The parameters are read off the tile's own record at every draw, so a
    /// picker moved in the tile's window reaches the next poll rather than
    /// the next launch. One reporter per clock: it keeps the last window it saw.
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {
        let reporter = env.claudeReporter()
        registry.register(
            factory: { tile in
                ClaudeUsageConnector(
                    reporter: reporter,
                    parameters: { tile.config?.parameters ?? .standard }
                )
            },
            for: Kind.id
        )
    }
}
