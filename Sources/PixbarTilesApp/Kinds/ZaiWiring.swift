import Foundation
import PixbarKit
import SwiftUI

struct ZaiWiring: TileKindWiring {
    typealias Kind = ZaiKind
    var tileGlyph: [String] { PanelGlyph.terminalTile }
    var namesItsOwnRefresh: Bool { true }

    /// The key is looked up at every read, never held: a key pasted into the
    /// tile's detail is on its way to the service at the next poll, and one
    /// removed from it is gone just as fast. The parameters are the same list
    /// the Claude tile takes, read off the record the same way.
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {
        let transport = env.transport
        let secrets = env.secrets
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
            for: Kind.id
        )
    }

    /// Carries no key: no clock produces through it.
    func namingInstance(_ naming: TileNaming) -> (any Connector)? {
        ZaiUsageConnector(source: ZaiUsageAPI(transport: naming.transport, key: { nil }))
    }

    func block(_ context: TileBlockContext<ZaiTileConfig>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZaiTileBlock(
                hasKey: context.model.hasZaiKey(for: context.key),
                outcome: context.model.lastZaiKeyOutcome,
                onSaveKey: { context.model.saveZaiKey($0, for: context.key) }
            )
            context.refresh("Refresh every")
            CodeUsageParametersBlock(settings: context.settings)
        }
    }
}
