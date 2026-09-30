import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// One wiring per kind: what the app builds, names and draws for it.
@MainActor
@Suite struct TileKindWiringTests {
    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

    @Test func everyKindHasExactlyOneWiring() {
        let wired = AppTileKinds.all.map(\.kindId)
        #expect(Set(wired).count == wired.count)
        #expect(Set(wired) == Set(TileKinds.all.map { $0.id }))
        #expect(AppTileKinds.wiring(for: "nope") == nil)
    }

    @Test func theClocksRegistryHoldsWhatTheWiringsRegister() {
        let defaults = UserDefaults(suiteName: "wiring-\(UUID().uuidString)")!
        let transport = StubTransport()
        let registry = ConnectorFactories(
            transport: transport, defaults: defaults, secrets: MemorySecretStore(),
            weather: OpenMeteoSource(transport: transport),
            anecdotes: StubConnector(id: AnecdotesKind.id, displayName: "Anecdotes")
        ).registry(for: clock)
        for kind in [WeatherKind.id, ClaudeKind.id, ZaiKind.id, GitHubKind.id] {
            let tile = TileRecord(
                key: TileKey(clockId: clock.id, connectorId: kind, instance: kind == GitHubKind.id ? "a/b" : ""),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
                config: kind == GitHubKind.id ? .github(GitHubTileConfig(repo: "a/b")) : nil
            )
            #expect(registry.connector(for: tile)?.id == kind, "kind \(kind)")
        }
        #expect(registry.connector(id: AnecdotesKind.id) != nil)
        #expect(registry.connector(id: VPNKind.id) == nil)
    }

    @Test func aTileWearsItsWiringsGlyph() {
        for wiring in AppTileKinds.all {
            #expect(PanelGlyph.tile(forConnectorId: wiring.kindId) == wiring.tileGlyph, "kind \(wiring.kindId)")
        }
        #expect(PanelGlyph.tile(forConnectorId: "nope") == PanelGlyph.unknownTile)
    }

    @Test func onlyTheUsageAndWeatherBlocksNameTheirOwnRefresh() {
        let naming = Set(AppTileKinds.all.filter(\.namesItsOwnRefresh).map(\.kindId))
        #expect(naming == [WeatherKind.id, ClaudeKind.id, ZaiKind.id])
    }

    @Test func theNamingInstancesAreTheWiringsInOrder() {
        #expect(ConnectorFactories.namingInstances(transport: StubTransport()).map(\.id) == [ZaiKind.id, GitHubKind.id])
    }
}
