import Foundation
import PixbarKit

struct GitHubWiring: TileKindWiring {
    typealias Kind = GitHubKind
    var tileGlyph: [String] { PanelGlyph.githubTile }

    /// One connector per repository, one token for all of them: the PAT sits
    /// under the connector's account, not the tile's, and is looked up at
    /// every read like the z.ai key. The snapshot is per tile, so each
    /// repository celebrates only what is new to itself; the store keys them
    /// by tile, so one store serves every tile on the clock. What each read
    /// found wrong goes beside the snapshot, for the clock's tile list to say
    /// (`AppModel.gitHubDiagnosis(of:)`).
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {
        let transport = env.transport
        let secrets = env.secrets
        let snapshots = UserDefaultsGitHubSnapshots(defaults: env.defaults)
        let diagnoses = UserDefaultsGitHubDiagnoses(defaults: env.defaults)
        // What GitHub refused the one token, shared by every tile's reads so
        // a rebuilt connector does not ask the refused query again.
        let refusals = GitHubRefusals()
        registry.register(
            factory: { tile in
                GitHubConnector(
                    tile: tile,
                    source: GitHubAPI(
                        transport: transport,
                        token: { secrets.secret(for: .connector(Kind.id)) },
                        refusals: refusals
                    ),
                    snapshots: snapshots,
                    diagnoses: diagnoses
                )
            },
            for: Kind.id
        )
    }

    /// Carries no token and no repository: no clock produces through it.
    func namingInstance(transport: any Transport) -> (any Connector)? {
        GitHubConnector(
            tile: TileRecord(
                key: TileKey(clockId: UUID(), connectorId: Kind.id),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60)
            ),
            source: GitHubAPI(transport: transport, token: { nil }),
            snapshots: NoGitHubSnapshots()
        )
    }
}

/// The naming instance's snapshot store: it never reads a state, so it never
/// has one to keep.
private struct NoGitHubSnapshots: GitHubSnapshotStoring {
    func snapshot(for tile: TileKey) -> GitHubSnapshot? { nil }
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {}
}
