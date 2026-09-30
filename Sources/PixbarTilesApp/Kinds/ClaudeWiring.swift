import Foundation
import PixbarKit
import SwiftUI

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

    func block(_ context: TileBlockContext<ClaudeTileConfig>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            context.refresh("Refresh every")
            CodeUsageParametersBlock(settings: context.settings)
            // Machine-wide state, one file, not a tile's: whatever tile's
            // window it is edited from edits it for every Claude tile.
            ClaudeCodeSettings(link: context.claudeCode())
        }
    }
}
