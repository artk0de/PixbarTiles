import Foundation
import PixbarKit
import SwiftUI
import Testing
@testable import PixbarTilesApp

/// A tile's settings block is its wiring's, and saves its kind's parameters.
@MainActor
@Suite struct TileBlockContextTests {
    private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

    private struct Bare: TileKindWiring {
        typealias Kind = AnecdotesKind
        var tileGlyph: [String] { [] }
    }

    @Test func aWiringWithNoBlockDrawsNothing() {
        #expect(Bare.Block.self == EmptyView.self)
    }

    @Test func aKindsParametersAreSavedThroughTheSettings() {
        let key = TileKey(clockId: desk.id, connectorId: GitHubKind.id, instance: "owner/repo")
        let github = ConnectorFactories.namingInstances(transport: StubTransport())
            .first { $0.id == GitHubKind.id }!
        let model = testModel(
            connectors: [github], clocks: [desk],
            tiles: [TileRecord(
                key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900),
                config: .github(GitHubTileConfig(repo: "owner/repo"))
            )],
            sessions: [desk.id: SpyHost()]
        )
        model.openDetail(for: key)
        let settings = TileSettingsModel(model: model, debounce: 0)

        #expect(settings.setParameters(GitHubTileConfig(repo: "owner/repo", celebrationSeconds: 3), kind: GitHubKind.self))
        #expect(model.storedTile(key)?.config?.github?.celebrationSeconds == 3)
        // Another kind's parameters are not this tile's to take.
        #expect(settings.setParameters(NoParameters(), kind: AnecdotesKind.self) == false)
    }
}
