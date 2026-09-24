// Tests/PixbarKitTests/GitHubConnectorTests.swift
import Foundation
import Testing
@testable import PixbarKit

// The connector glues the source, the detector and the snapshot together. The
// source is a stub answering a queue of states (or a failure), the snapshot
// store lives in memory, so every case here is posed without a network or a
// defaults domain.

/// Answers each read with the next queued answer, and records which repo was
/// asked for. The last answer repeats once the queue runs dry.
private final class StubGitHub: GitHubReporting, @unchecked Sendable {
    enum Answer {
        case state(GitHubRepoState?)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var asked: [String] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    var repos: [String] { lock.withLock { asked } }

    func state(of repo: String) async throws -> GitHubRepoState? {
        let answer = lock.withLock { () -> Answer in
            asked.append(repo)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        switch answer {
        case let .state(state): return state
        case let .failure(error): throw error
        }
    }
}

private final class MemoryGitHubSnapshots: GitHubSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TileKey: GitHubSnapshot] = [:]

    func snapshot(for tile: TileKey) -> GitHubSnapshot? {
        lock.withLock { stored[tile] }
    }

    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {
        lock.withLock { stored[tile] = snapshot }
    }
}

private let clockId = UUID(uuidString: "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F")!
private let moment = Date(timeIntervalSince1970: 1_760_000_000)

private func tile(_ repo: String = "a/x") -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clockId, connectorId: GitHubConnector.connectorId, instance: repo),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
        config: .github(GitHubTileConfig(repo: repo))
    )
}

private func state(stars: [Stargazer]) -> GitHubRepoState {
    GitHubRepoState(
        nameWithOwner: "a/x", stars: 100 + stars.count, forks: 3, openPRs: 0,
        stargazers: stars, forkEvents: [], openPRNumbers: []
    )
}

@Suite struct GitHubConnectorTests {
    @Test func aMissingTokenReadsNoToken() async throws {
        let snapshots = MemoryGitHubSnapshots()
        let connector = GitHubConnector(
            tile: tile(), source: StubGitHub([.state(nil)]), snapshots: snapshots
        )

        let reading = try await connector.read()

        #expect(reading.content == .noToken)
        #expect(reading.events.isEmpty)
        #expect(reading.config.repo == "a/x")
        #expect(snapshots.snapshot(for: tile().key) == nil)
    }

    @Test func aFailureReadsNoDataAndKeepsTheSnapshot() async throws {
        let snapshots = MemoryGitHubSnapshots()
        let kept = GitHubSnapshot(
            lastStarAt: moment, lastForkAt: nil, openPRs: [7], stars: 100, forks: 3, lastPRNumber: 7
        )
        snapshots.save(kept, for: tile().key)
        let connector = GitHubConnector(
            tile: tile(), source: StubGitHub([.failure(GitHubAPI.Failure.status(502))]),
            snapshots: snapshots
        )

        let reading = try await connector.read()

        #expect(reading.content == .noData)
        #expect(reading.events.isEmpty)
        #expect(snapshots.snapshot(for: tile().key) == kept)
    }

    @Test func theSecondReadCarriesTheNewStars() async throws {
        let old = Stargazer(login: "bob", starredAt: moment)
        let new = Stargazer(login: "alice", starredAt: moment.addingTimeInterval(60))
        let first = state(stars: [old])
        let second = state(stars: [old, new])
        let snapshots = MemoryGitHubSnapshots()
        let connector = GitHubConnector(
            tile: tile(), source: StubGitHub([.state(first), .state(second)]), snapshots: snapshots
        )

        let baseline = try await connector.read()
        #expect(baseline.content == .state(first))
        #expect(baseline.events.isEmpty)
        #expect(snapshots.snapshot(for: tile().key)?.lastStarAt == moment)

        let next = try await connector.read()
        #expect(next.content == .state(second))
        #expect(next.events.newStars == ["alice"])
        #expect(next.events.newStarCount == 1)
        #expect(snapshots.snapshot(for: tile().key)?.lastStarAt == new.starredAt)
    }

    @Test func itIsInstancedPerKey() {
        let connector = GitHubConnector(
            tile: tile(), source: StubGitHub([.state(nil)]), snapshots: MemoryGitHubSnapshots()
        )

        #expect(connector.id == "github")
        #expect(connector.instancing == .perKey)
        #expect(connector.defaultInterval == 60)
        #expect(connector.isAudible == false)
        #expect(connector.isAmbient == false)
    }

    // A tile stored without a repo — added from the store before its settings
    // were filled in — asks nothing and reads as no data, rather than sending
    // an empty name to GitHub or crashing on it.
    @Test func aTileWithoutARepoReadsNoDataAndAsksNothing() async throws {
        let source = StubGitHub([.state(state(stars: []))])
        let bare = TileRecord(
            key: TileKey(clockId: clockId, connectorId: GitHubConnector.connectorId),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60)
        )
        let connector = GitHubConnector(tile: bare, source: source, snapshots: MemoryGitHubSnapshots())

        let reading = try await connector.read()

        #expect(reading.content == .noData)
        #expect(source.repos.isEmpty)
    }

    // The store's card: the Dev shelf, a star, and its line; offered on both
    // models, and still offered on a clock that already carries one repo.
    @Test func theCatalogueListsItAndKeepsItAvailableBesideAnotherRepo() {
        let connector = GitHubConnector(
            tile: tile(), source: StubGitHub([.state(nil)]), snapshots: MemoryGitHubSnapshots()
        )
        let candidate = TileCandidate(connector)
        let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.2")
        let placed = TileRecord(
            key: TileKey(clockId: desk.id, connectorId: "github", instance: "a/x"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60)
        )

        #expect(candidate.category == .dev)
        #expect(candidate.storeIcon == "star")
        #expect(candidate.blurb == "A repository's stars, forks and PRs")
        #expect(candidate.models == [.awtrix3, .ulanziTC002])
        #expect(
            TileCatalogue.availability(of: candidate, on: desk, tiles: [placed], clocks: [desk])
                == .available
        )
    }

    // Nothing of it plays on the Mac, so a GitHub tile on one clock is not
    // "already speaking" for another: the second clock is offered it too.
    @Test func aGitHubTileOnAnotherClockLeavesItAvailableHere() {
        let candidate = TileCandidate(GitHubConnector(
            tile: tile(), source: StubGitHub([.state(nil)]), snapshots: MemoryGitHubSnapshots()
        ))
        let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.2")
        let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.3")
        let onDesk = TileRecord(
            key: TileKey(clockId: desk.id, connectorId: "github", instance: "a/x"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60)
        )

        #expect(
            TileCatalogue.availability(
                of: candidate, on: kitchen, tiles: [onDesk], clocks: [desk, kitchen]
            ) == .available
        )
    }
}
