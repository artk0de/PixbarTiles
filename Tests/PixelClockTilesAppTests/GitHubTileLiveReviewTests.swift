// Tests/PixelClockTilesAppTests/GitHubTileLiveReviewTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The live-review round in the app (spec "Live-review amendments
// (2026-09-24)"): the token help as measured, a pasted URL reduced to
// `owner/name`, a repository that can change, Show / Notify / Main watch in
// the block, a token save that redraws the preview, and the failure — or the
// missing permission — said in the preview and on the clock's tile list.

/// Answers with the token the secret store holds: nothing without one, a
/// state with one, and `failure` when set.
private struct SecretReadingSource: GitHubReporting {
    let secrets: any SecretStoring
    var failure: GitHubAPI.Failure?

    func state(of repo: String) async throws -> GitHubRepoState? {
        guard secrets.secret(for: .connector(GitHubConnector.connectorId)) != nil else { return nil }
        if let failure { throw failure }
        return GitHubRepoState(nameWithOwner: repo, stars: 1234, forks: 45, openPRs: 3)
    }
}

private struct NoSnapshots: GitHubSnapshotStoring {
    func snapshot(for tile: TileKey) -> GitHubSnapshot? { nil }
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {}
}

@MainActor
@Suite struct GitHubTileLiveReviewTests {
    private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.5")

    private var github: any Connector {
        ConnectorFactories.namingInstances(transport: StubTransport())
            .first { $0.id == GitHubConnector.connectorId }!
    }

    private func key(_ repo: String) -> TileKey {
        TileKey(clockId: desk.id, connectorId: GitHubConnector.connectorId, instance: repo)
    }

    private func tile(_ repo: String, config: GitHubTileConfig? = nil) -> TileRecord {
        TileRecord(
            key: key(repo),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900),
            config: .github(config ?? GitHubTileConfig(repo: repo))
        )
    }

    private func makeModel(
        tiles: [TileRecord], secrets: any SecretStoring = MemorySecretStore(),
        failure: GitHubAPI.Failure? = nil, defaults: UserDefaults? = nil,
        sessions: [UUID: any ConnectorRunning]? = nil
    ) -> AppModel {
        let own = ConnectorRegistry()
        own.register(
            factory: { record in
                GitHubConnector(
                    tile: record, source: SecretReadingSource(secrets: secrets, failure: failure),
                    snapshots: NoSnapshots()
                )
            },
            for: GitHubConnector.connectorId
        )
        return testModel(
            connectors: [github],
            defaults: defaults ?? UserDefaults(suiteName: "github-review-\(UUID().uuidString)")!,
            clocks: [desk], tiles: tiles, secrets: secrets,
            sessions: sessions ?? [desk.id: SpyHost()],
            makeClockRegistry: { _ in own }
        )
    }

    // MARK: - The token help, as measured

    /// The link itself is `GitHubTileSettingsTests.theHelpLinkIsThePrefilledForm`.
    @Test func theHelpSaysWhatAReadOnlyTokenSees() {
        #expect(GitHubTokenHelp.createURL(.privateRepos, owner: nil).absoluteString.hasSuffix("&contents=read"))
        for phrase in [
            "Public repositories", "Only select repositories", "Metadata: read", "Pull requests: read",
            "Commit statuses: read", "Checks: read", "Contents: read", "Who starred",
        ] {
            #expect(GitHubTokenHelp.text.contains(phrase), "\(phrase)")
        }
        // The account permission does not name who starred a repository.
        #expect(GitHubTokenHelp.text.contains("Starring") == false)
    }

    // MARK: - A pasted URL

    @Test func aPastedURLIsReducedToOwnerAndName() {
        let cases = [
            ("https://github.com/artk0de/TeaRAGs-MCP", "artk0de/TeaRAGs-MCP"),
            ("http://github.com/o/n/", "o/n"),
            ("github.com/o/n", "o/n"),
            ("https://github.com/o/n.git", "o/n"),
            ("git@github.com:o/n.git", "o/n"),
            ("https://github.com/o/n/pull/12", "o/n"),
            ("https://github.com/o/n/tree/main/Sources/App", "o/n"),
            ("www.github.com/o/n", "o/n"),
            ("  https://www.github.com/O/N  \n", "O/N"),
            ("o/n", "o/n"),
            (" Owner/Name ", "Owner/Name"),
        ]
        for (typed, repo) in cases {
            #expect(GitHubRepoName.repo(from: typed) == repo, "\(typed)")
            #expect(GitHubRepoName.normalised(typed) == repo, "\(typed)")
        }
        for refused in ["", "owner", "https://gitlab.com/o/n", "https://github.com/o", "a/b/c", "own er/name"] {
            #expect(GitHubRepoName.repo(from: refused) == nil, "\(refused)")
        }
        // Left as typed when it cannot be read as a repository.
        #expect(GitHubRepoName.normalised(" owner ") == "owner")
    }

    @Test func theStoreSheetTakesAPastedURL() throws {
        let model = makeModel(tiles: [])
        let store = StoreModel(model: model)
        store.show(desk.id)
        let card = try #require(store.cards.first { $0.candidate.connectorId == GitHubConnector.connectorId })
        store.add(card)

        #expect(store.addGitHub(repo: "https://github.com/Owner/Name.git"))

        let added = try #require(model.storedTile(key("owner/name")))
        #expect(added.config?.github?.repo == "Owner/Name")
    }

    // MARK: - A repository that can change

    @Test func changingTheRepoReKeysTheTileInPlace() throws {
        var kept = GitHubTileConfig(repo: "a/x", shortName: "ax", celebrationSeconds: 15)
        kept.showForks = false
        kept.notifyPRs = false
        kept.mainWatch = .prs
        let first = tile("first/one"), mine = tile("a/x", config: kept), last = tile("last/one")
        let model = makeModel(tiles: [first, mine, last])
        model.openDetail(for: mine.key)

        #expect(model.changeGitHubRepo(mine.key, to: "https://github.com/B/Y") == .saved)

        let moved = key("b/y")
        #expect(model.tileRecords.map(\.key) == [first.key, moved, last.key])
        var expected = kept
        expected.repo = "B/Y"
        #expect(model.storedTile(moved)?.config?.github == expected)
        #expect(model.storedTile(mine.key) == nil)
        #expect(model.detailTileKey == moved)
    }

    @Test func aRepoAlreadyOnTheClockIsRefused() {
        let a = tile("a/x"), b = tile("b/y")
        let model = makeModel(tiles: [a, b])

        #expect(model.changeGitHubRepo(a.key, to: "B/Y") != .saved)
        #expect(model.changeGitHubRepo(a.key, to: "not a repo") != .saved)
        #expect(model.tileRecords.map(\.key) == [a.key, b.key])
    }

    /// The same repository in another case is the same tile: only the
    /// spelling moves.
    @Test func aChangeOfCaseKeepsTheKey() {
        let a = tile("a/x")
        let model = makeModel(tiles: [a])

        #expect(model.changeGitHubRepo(a.key, to: "A/X") == .saved)
        #expect(model.storedTile(a.key)?.config?.github?.repo == "A/X")
    }

    /// The old page leaves the clock, and the new repository starts from a
    /// baseline: whatever snapshot its key held is gone.
    @Test func theOldPageIsRemovedAndTheNewRepoStartsFromABaseline() async throws {
        let defaults = UserDefaults(suiteName: "github-rekey-\(UUID().uuidString)")!
        let pages = SpyUlanziPages()
        let a = tile("a/x")
        let model = makeModel(tiles: [a], defaults: defaults, sessions: [desk.id: pages])
        let snapshots = UserDefaultsGitHubSnapshots(defaults: defaults)
        snapshots.save(GitHubSnapshot(lastStarAt: nil, lastForkAt: nil, openPRs: [1]), for: key("b/y"))

        #expect(model.changeGitHubRepo(a.key, to: "b/y") == .saved)

        #expect(await waitUntil { pages.events.contains("removed:\(a.key.tileId)") })
        #expect(snapshots.snapshot(for: key("b/y")) == nil)
        await model.teardown()
    }

    @Test func theSettingsWindowSaysWhyARepoWasRefused() async {
        let a = tile("a/x"), b = tile("b/y")
        let model = makeModel(tiles: [a, b])
        model.openDetail(for: a.key)
        let settings = TileSettingsModel(model: model)

        #expect(settings.setGitHubRepo("b/y") == false)
        #expect(settings.lastRefusal == "b/y is already on Desk")
        #expect(settings.setGitHubRepo("c/z"))
        #expect(settings.lastRefusal == nil)
        #expect(await waitUntil { settings.key == key("c/z") })
        await model.teardown()
    }

    // MARK: - Show, Notify, Main watch

    @Test func theTogglesAndTheMainWatchAreSaved() {
        let a = tile("a/x")
        let model = makeModel(tiles: [a])
        model.openDetail(for: a.key)
        let settings = TileSettingsModel(model: model)
        var edited = GitHubTileConfig(repo: "a/x")
        edited.showCI = false
        edited.notifyStars = false
        edited.mainWatch = .ci

        settings.setGitHubConfig(edited)

        #expect(model.storedTile(a.key)?.config?.github == edited)
    }

    // MARK: - The token, and what the preview says

    @Test func savingTheTokenRedrawsTheOpenPreview() async {
        let a = tile("a/x")
        let model = makeModel(tiles: [a])
        let settings = TileSettingsModel(model: model)
        model.openDetail(for: a.key)
        #expect(await waitUntil { settings.preview != nil })
        let withoutToken = settings.preview

        #expect(settings.saveGitHubToken("github_pat_new") == .saved)

        #expect(await waitUntil { settings.preview != nil && settings.preview != withoutToken })
        #expect(model.hasGitHubToken)
        await model.teardown()
    }

    @Test func thePreviewSaysWhyThereIsNoReadingBesideThePicture() async throws {
        let secrets = MemorySecretStore()
        try secrets.save("github_pat_old", for: .connector("github"))
        let a = tile("a/x")
        let model = makeModel(tiles: [a], secrets: secrets, failure: .status(401))
        let settings = TileSettingsModel(model: model)
        model.openDetail(for: a.key)

        #expect(await waitUntil { settings.previewNote != nil })
        #expect(settings.previewNote == "GitHub refused the token (401) — paste a new one")
        #expect(settings.preview != nil)
        await model.teardown()
    }

    // MARK: - The tile list

    /// The clock's tile list names the failure, or the permission the token
    /// lacks — read through the factories the sessions run.
    @Test func theTileListSaysWhatTheLastReadFound() async throws {
        let defaults = UserDefaults(suiteName: "github-row-\(UUID().uuidString)")!
        let secrets = MemorySecretStore()
        try secrets.save("github_pat_old", for: .connector("github"))
        let refused = StubTransport(status: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8))
        let registry = ConnectorFactories(
            transport: refused, defaults: defaults, secrets: secrets,
            weather: OpenMeteoSource(transport: refused), anecdotes: StubConnector(id: "anecdotes")
        ).registry(for: desk)
        let a = tile("a/x")
        let model = testModel(connectors: [github], defaults: defaults, clocks: [desk], tiles: [a], secrets: secrets)

        _ = try await #require(registry.connector(for: a) as? GitHubConnector).read()

        #expect(model.gitHubDiagnosis(of: a.key)
            == GitHubDiagnosis(message: "GitHub refused the token (401) — paste a new one", isQuiet: false))
        await model.teardown()
    }
}

/// The TC002 slot's event half, recorded — what the model asked the clock to
/// do to which page.
private final class SpyUlanziPages: ConnectorRunning, UlanziConnectorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }

    private func note(_ event: String) { lock.withLock { recorded.append(event) } }

    func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
    func runOnce(tile: TileRecord) async -> RunResult { .delivered }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
    func restoreDeviceState(borrowedBy tileId: String?) async { note("restore:\(tileId ?? "all")") }
    var indicators: IndicatorCustody? { nil }

    func deliver(_ output: UlanziDelivery, toTile tileId: String) async -> RunResult { .delivered }
    func markIdle(tileId: String) async -> RunResult {
        note("idle:\(tileId)")
        return .delivered
    }
    func tileRemoved(_ tileId: String) async { note("removed:\(tileId)") }
    func shutdown() async {}
}
