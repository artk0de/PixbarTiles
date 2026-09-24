// Tests/PixelClockTilesAppTests/GitHubTileSettingsTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// A GitHub tile's settings: the repository is the tile's identity, so it is
// asked for before the tile exists and never edited after; the short name and
// the celebration length are the tile's own; the token is ONE, shared by every
// GitHub tile in the app, and filed under the connector's account.

@MainActor
@Suite struct GitHubTileSettingsTests {
    private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.5")
    private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")

    /// The app's own naming instance: a GitHub connector the catalogue offers
    /// on both clock models.
    private var github: any Connector {
        ConnectorFactories.namingInstances(transport: StubTransport())
            .first { $0.id == GitHubConnector.connectorId }!
    }

    private func key(_ repo: String, on clock: ClockRecord) -> TileKey {
        TileKey(clockId: clock.id, connectorId: GitHubConnector.connectorId, instance: repo)
    }

    private func tile(_ repo: String, on clock: ClockRecord) -> TileRecord {
        TileRecord(
            key: key(repo, on: clock),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900),
            config: .github(GitHubTileConfig(repo: repo))
        )
    }

    private func makeModel(
        tiles: [TileRecord] = [], secrets: any SecretStoring = MemorySecretStore()
    ) -> AppModel {
        testModel(
            connectors: [github], clocks: [desk, kitchen], tiles: tiles, secrets: secrets,
            sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
        )
    }

    private func gitHubTiles(_ model: AppModel) -> [TileRecord] {
        model.tileRecords.filter { $0.key.connectorId == GitHubConnector.connectorId }
    }

    // MARK: - The shared token

    @Test func theTokenIsSharedByEveryGitHubTile() {
        let secrets = MemorySecretStore()
        let a = tile("a/x", on: desk)
        let b = tile("b/y", on: desk)
        let model = makeModel(tiles: [a, b], secrets: secrets)
        #expect(model.hasGitHubToken == false)

        // Saved from tile A's window…
        model.openDetail(for: a.key)
        #expect(model.saveGitHubToken("  github_pat_shared\n") == .saved)

        // …and tile B's window says the same thing.
        model.openDetail(for: b.key)
        #expect(model.hasGitHubToken)
        #expect(secrets.secret(for: .connector("github")) == "github_pat_shared")
        #expect(secrets.secret(for: .tile(a.key)) == nil)
        #expect(secrets.secret(for: .tile(b.key)) == nil)
    }

    @Test func aBlankTokenRemovesIt() throws {
        let secrets = MemorySecretStore()
        try secrets.save("github_pat_old", for: .connector("github"))
        let model = makeModel(tiles: [tile("a/x", on: desk)], secrets: secrets)

        #expect(model.saveGitHubToken("   ") == .removed)
        #expect(model.hasGitHubToken == false)
        #expect(secrets.secret(for: .connector("github")) == nil)
    }

    // MARK: - Adding a tile

    @Test func aBadRepoIsRefused() {
        let model = makeModel()

        for typed in ["", "owner", "owner/", "/name", "a/b/c", "own er/name", "owner/na:me"] {
            #expect(model.addGitHubTile(repo: typed, to: desk.id) == false, "\(typed)")
        }
        #expect(gitHubTiles(model).isEmpty)
    }

    @Test func theInstanceIsTheLowercasedRepo() throws {
        let model = makeModel()

        #expect(model.addGitHubTile(repo: " Apple/Swift-NIO ", to: desk.id))

        let added = try #require(gitHubTiles(model).first)
        #expect(added.key == key("apple/swift-nio", on: desk))
        #expect(added.config?.github?.repo == "Apple/Swift-NIO")
    }

    @Test func aDuplicateRepoOnOneClockIsRefused() {
        let model = makeModel()

        #expect(model.addGitHubTile(repo: "a/x", to: desk.id))
        #expect(model.addGitHubTile(repo: "A/X", to: desk.id) == false)
        #expect(model.addGitHubTile(repo: "b/y", to: desk.id))
        #expect(gitHubTiles(model).map(\.key.instance).sorted() == ["a/x", "b/y"])
    }

    @Test func theSameRepoOnTwoClocksIsAllowed() {
        let model = makeModel()

        #expect(model.addGitHubTile(repo: "a/x", to: desk.id))
        #expect(model.addGitHubTile(repo: "a/x", to: kitchen.id))
        #expect(Set(gitHubTiles(model).map(\.key.clockId)) == [desk.id, kitchen.id])
    }

    // MARK: - The store asks first

    @Test func addingGitHubInTheStoreAsksForTheRepoFirst() throws {
        let model = makeModel()
        let store = StoreModel(model: model)
        store.show(desk.id)
        let card = try #require(store.cards.first { $0.candidate.connectorId == GitHubConnector.connectorId })

        store.add(card)
        // Nothing on the clock yet: the repository is the tile's identity.
        #expect(gitHubTiles(model).isEmpty)
        #expect(store.askingForRepo == card)

        #expect(store.addGitHub(repo: "Owner/Name"))
        #expect(store.askingForRepo == nil)
        #expect(store.lastAdded == key("owner/name", on: desk))
        #expect(model.detailTileKey == key("owner/name", on: desk))
    }

    @Test func aRefusedRepoInTheStoreSaysWhy() throws {
        let model = makeModel(tiles: [tile("owner/name", on: desk)])
        let store = StoreModel(model: model)
        store.show(desk.id)
        let card = try #require(store.cards.first { $0.candidate.connectorId == GitHubConnector.connectorId })
        store.add(card)

        #expect(store.addGitHub(repo: "owner/name") == false)
        #expect(store.lastRefusal != nil)
        #expect(store.lastAdded == nil)
    }

    // MARK: - The tile's own settings

    @Test func theShortNameAndTheCelebrationAreTheTilesOwnAndTheRepoStays() throws {
        let a = tile("a/x", on: desk)
        let model = makeModel(tiles: [a])
        model.openDetail(for: a.key)
        let settings = TileSettingsModel(model: model)

        settings.setGitHubConfig(GitHubTileConfig(repo: "someone/else", shortName: "pct", celebrationSeconds: 10))
        #expect(model.storedTile(a.key)?.config?.github
            == GitHubTileConfig(repo: "a/x", shortName: "pct", celebrationSeconds: 10))

        // An emptied short name is no short name.
        settings.setGitHubConfig(GitHubTileConfig(repo: "a/x", shortName: "  ", celebrationSeconds: 10))
        #expect(model.storedTile(a.key)?.config?.github?.shortName == nil)
    }

    @Test func aNameWiderThanTheAreaIsSaidToScroll() {
        #expect(GitHubTileBlock.scrollNote(repo: "artk0de/pixelclocktiles", shortName: nil) != nil)
        #expect(GitHubTileBlock.scrollNote(repo: "artk0de/pixelclocktiles", shortName: "pct") == nil)
        #expect(GitHubTileBlock.scrollNote(repo: "a/x", shortName: nil) == nil)
        #expect(GitHubTileBlock.scrollNote(repo: "a/x", shortName: "a much longer short name") != nil)
    }

    // MARK: - The help

    @Test func theHelpLinkIsThePrefilledForm() {
        #expect(GitHubTokenHelp.createURL.absoluteString
            == "https://github.com/settings/personal-access-tokens/new?name=PixelClockTiles&description=Read-only+stars,+forks,+PRs+and+CI+for+the+GitHub+tile&expires_in=366&metadata=read&pull_requests=read&statuses=read&checks=read")
        for phrase in [
            "Public repositories", "Metadata: read", "Pull requests: read",
            "Commit statuses: read", "Checks: read",
        ] {
            #expect(GitHubTokenHelp.text.contains(phrase), "\(phrase)")
        }
    }

    @Test func theQuestionMarkIsDrawnInThePanelsPixels() {
        #expect(PanelGlyph.question == [
            ".###.",
            "#...#",
            "...#.",
            "..#..",
            "..#..",
            ".....",
            "..#..",
        ])
    }
}
