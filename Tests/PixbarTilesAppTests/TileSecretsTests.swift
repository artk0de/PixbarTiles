import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The keys and tokens tiles read through, and the GitHub tiles they unlock.
@MainActor
@Suite struct TileSecretsTests {
    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    private let defaults = UserDefaults(suiteName: "secrets-\(UUID().uuidString)")!
    private let store = MemorySecretStore()

    private func secrets() -> (TileSecrets, TileBook) {
        let book = inertTileBook(clock: clock, defaults: defaults, connectors: [
            StubConnector(id: "zai", displayName: "z.ai"),
            StubConnector(id: GitHubConnector.connectorId, displayName: "GitHub", instancing: .perKey),
        ])
        return (TileSecrets(secrets: store, defaults: defaults, book: book), book)
    }

    @Test func aPastedKeyIsFiledAwayAndOnlyItsHandleJoinsTheTile() {
        let (subject, book) = secrets()
        let key = TileKey(clockId: clock.id, connectorId: "zai")
        #expect(book.addTile("zai", to: clock.id) == .saved)
        #expect(subject.saveZaiKey("  sk-123 \n", for: key) == .saved)
        #expect(store.secret(for: .tile(key)) == "sk-123")
        #expect(subject.hasZaiKey(for: key))
        guard case let .zai(config)? = book.storedTile(key)?.config else {
            Issue.record("the tile carries no z.ai config")
            return
        }
        #expect(config.keyAccount == ZaiTileConfig.account(for: key))
        #expect(subject.saveZaiKey("", for: key) == .removed)
        #expect(subject.hasZaiKey(for: key) == false)
        #expect(subject.lastZaiKeyOutcome == .removed)
    }

    @Test func theGitHubTokenIsOneForEveryTile() {
        let (subject, _) = secrets()
        #expect(subject.hasGitHubToken == false)
        #expect(subject.saveGitHubToken("ghp_x") == .saved)
        #expect(subject.hasGitHubToken)
        #expect(subject.lastGitHubTokenOutcome == .saved)
    }

    @Test func aRepositoryIsAddedByNameAndMovedByName() {
        let (subject, book) = secrets()
        #expect(subject.addGitHubTile(repo: "not a repo", to: clock.id) == false)
        #expect(subject.addGitHubTile(repo: "Owner/Repo", to: clock.id))
        let key = TileKey(clockId: clock.id, connectorId: GitHubConnector.connectorId, instance: "owner/repo")
        #expect(book.storedTile(key)?.config?.github?.repo == "Owner/Repo")
        if case .refused = subject.changeGitHubRepo(key, to: "nope") {} else { Issue.record("a malformed name was taken") }
        #expect(subject.changeGitHubRepo(key, to: "owner/other") == .saved)
        #expect(book.tileRecords.map(\.key.instance) == ["owner/other"])
    }
}
