// Tests/PixelClockTilesAppTests/GitHubTileWiringTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Two GitHub tiles on one clock are two connectors, each asking for its own
// repository with the one shared token. Read through the factories the
// sessions are built from; the transport records the requests, and its empty
// answer makes each read `.noData`, which is beside the point here.

@MainActor
@Suite struct GitHubTileWiringTests {
    private let clock = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.5")

    private func tile(_ repo: String) -> TileRecord {
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: GitHubConnector.connectorId, instance: repo),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
            config: .github(GitHubTileConfig(repo: repo))
        )
    }

    /// The GraphQL variables a request carried.
    private func variables(_ request: URLRequest) throws -> [String: String] {
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object["variables"] as? [String: String])
    }

    // The store's cards are drawn from the app's own registry: the GitHub
    // tile is offered because a naming instance of it is registered there,
    // after z.ai, as a per-key connector.
    @Test func theStoreIsOfferedTheGitHubTile() {
        let named = ConnectorFactories.namingInstances(transport: StubTransport())

        #expect(named.map(\.id) == [ZaiUsageConnector.connectorId, GitHubConnector.connectorId])
        #expect(named.last?.instancing == .perKey)
    }

    @Test func twoTilesOnOneClockAskForTheirOwnRepos() async throws {
        let transport = StubTransport(body: Data("{}".utf8))
        let secrets = MemorySecretStore()
        try secrets.save("github_pat_shared", for: .connector("github"))
        let defaults = UserDefaults(suiteName: "github-wiring-\(UUID().uuidString)")!
        let registry = ConnectorFactories(
            transport: transport, defaults: defaults, secrets: secrets,
            weather: OpenMeteoSource(transport: transport), anecdotes: StubConnector(id: "anecdotes")
        ).registry(for: clock)

        for repo in ["a/x", "b/y"] {
            let connector = try #require(registry.connector(for: tile(repo)) as? GitHubConnector)
            let reading = try await connector.read()
            #expect(reading.config.repo == repo)
        }

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(try requests.map { try variables($0) } == [
            ["owner": "a", "name": "x"], ["owner": "b", "name": "y"],
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_shared"
        })
    }
}
