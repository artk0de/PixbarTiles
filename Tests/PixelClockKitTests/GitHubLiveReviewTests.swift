// Tests/PixelClockKitTests/GitHubLiveReviewTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The live-review round (spec "Live-review amendments (2026-09-24)" and
// "Partial answers are kept"): a failure said by name, a stargazers-only
// refusal that keeps the counts, and the tile's Show and Notify toggles.

private let clockId = UUID(uuidString: "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F")!
private let moment = Date(timeIntervalSince1970: 1_760_000_000)

/// Answers every read with one answer.
private struct FixedSource: GitHubReporting {
    let answer: @Sendable () throws -> GitHubRepoState?
    func state(of repo: String) async throws -> GitHubRepoState? { try answer() }
}

private final class Snapshots: GitHubSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TileKey: GitHubSnapshot] = [:]

    func snapshot(for tile: TileKey) -> GitHubSnapshot? { lock.withLock { stored[tile] } }
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) { lock.withLock { stored[tile] = snapshot } }
}

private func record(_ config: GitHubTileConfig) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clockId, connectorId: GitHubConnector.connectorId, instance: config.repo),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
        config: .github(config)
    )
}

private func connector(
    _ config: GitHubTileConfig = GitHubTileConfig(repo: "a/x"), snapshots: Snapshots = Snapshots(),
    answer: @escaping @Sendable () throws -> GitHubRepoState?
) -> GitHubConnector {
    GitHubConnector(tile: record(config), source: FixedSource(answer: answer), snapshots: snapshots)
}

/// A GraphQL answer: `repository` as given (or null) and `errors` as given.
private func body(repository: String?, errors: String?) -> Data {
    var fields: [String] = []
    fields.append(#""data":{"repository":\#(repository ?? "null")}"#)
    if let errors { fields.append(#""errors":\#(errors)"#) }
    return Data("{\(fields.joined(separator: ","))}".utf8)
}

/// The repository with `stargazers` as given — null when refused.
private func repository(stargazers: String) -> String {
    """
    {"nameWithOwner":"a/x","stargazerCount":12,"forkCount":3,"pullRequests":{"totalCount":1},
     "stargazers":\(stargazers),"forks":{"nodes":[]},"openPRs":{"nodes":[{"number":7,"author":{"login":"dave"}}]},
     "defaultBranchRef":null}
    """
}

private let refusedStargazers = """
[{"type":"FORBIDDEN","path":["repository","stargazers"],"locations":[{"line":6,"column":5}],
  "message":"Resource not accessible by personal access token"}]
"""

// MARK: - Failures by name

@Suite struct GitHubFailureByNameTests {
    @Test func a401ReadsBadToken() async throws {
        let reading = try await connector { throw GitHubAPI.Failure.status(401) }.read()
        #expect(reading.content == .badToken)
    }

    @Test func aRepositoryGitHubWillNotShowReadsNoRepo() async throws {
        for failure in [GitHubAPI.Failure.notFound("Could not resolve"), .badRepo("x")] {
            let reading = try await connector { throw failure }.read()
            #expect(reading.content == .noRepo, "\(failure)")
        }
    }

    @Test func everythingElseReadsNoData() async throws {
        let failures: [any Error] = [
            GitHubAPI.Failure.status(502), GitHubAPI.Failure.status(403), GitHubAPI.Failure.graphQL("boom"),
            URLError(.notConnectedToInternet),
        ]
        for failure in failures {
            let reading = try await connector { throw failure }.read()
            #expect(reading.content == .noData, "\(failure)")
        }
    }

    @Test func aFailureByNameKeepsTheSnapshot() async throws {
        let snapshots = Snapshots()
        let kept = GitHubSnapshot(lastStarAt: moment, lastForkAt: nil, openPRs: [7], stars: 12, forks: 3)
        let subject = connector(snapshots: snapshots) { throw GitHubAPI.Failure.status(401) }
        snapshots.save(kept, for: subject.tile)

        _ = try await subject.read()

        #expect(snapshots.snapshot(for: subject.tile) == kept)
    }

    @Test func graphQLsNotFoundIsItsOwnFailure() throws {
        let errors = #"[{"type":"NOT_FOUND","path":["repository"],"message":"Could not resolve to a Repository"}]"#
        #expect(throws: GitHubAPI.Failure.notFound("Could not resolve to a Repository")) {
            _ = try GitHubAPI.decode(body(repository: nil, errors: errors), repo: "a/x")
        }
    }

    /// The TC002 face says which, in the label slot; `no data` keeps its own
    /// icon, the two others wear the dim mark.
    @Test func theTC002FaceSaysWhich() throws {
        let config = GitHubTileConfig(repo: "a/x")
        for (content, problem) in [(GitHubReading.Content.badToken, GitHubProblem.token), (.noRepo, .repo)] {
            let delivery = GitHubFace.delivery(for: GitHubReading(content: content, config: config))
            let frames = GitHubFace.timeline(ambient: nil, noToken: false, config: config, problem: problem)
            #expect(delivery.scene == GitHubFace.scene(frames), "\(content)")
            #expect(frames != GitHubFace.timeline(ambient: nil, noToken: false, config: config), "\(content)")
        }
        #expect(GitHubProblem.token.label == "bad token")
        #expect(GitHubProblem.repo.label == "no repo")
        #expect(GitHubProblem.data.label == "no data")
    }

    @Test func theTC001LineSaysTheSameWords() {
        let config = GitHubTileConfig(repo: "a/x")
        for (content, words) in [(GitHubReading.Content.badToken, "bad token"), (.noRepo, "no repo")] {
            let delivery = GitHubAwtrixFace.draw(GitHubReading(content: content, config: config), appName: "g")
            #expect(delivery.text == words)
            #expect(delivery.color == GitHubAwtrixFace.quietColour)
            #expect(delivery.interruptions.isEmpty)
        }
    }

    /// The settings preview and the tile list say it in a sentence.
    @Test func thePreviewSaysItInASentence() {
        let config = GitHubTileConfig(repo: "a/x")
        let notes: [(GitHubReading.Content, String?)] = [
            (.badToken, "GitHub refused the token (401) — paste a new one"),
            (.noRepo, "Repository not found, or the token can't see it (Repository access)"),
            (.noData, "GitHub could not be reached"),
            (.noToken, nil),
            (.state(GitHubRepoState(nameWithOwner: "a/x", stars: 1, forks: 0, openPRs: 0)), nil),
        ]
        for (content, note) in notes {
            let reading = GitHubReading(content: content, config: config)
            #expect(reading.previewNote == note, "\(content)")
            #expect(reading.diagnosis?.isQuiet ?? false == false, "\(content)")
        }
    }

    /// The diagnosis is kept per tile for the tile list, and a clean read
    /// clears it.
    @Test func theDiagnosisIsKeptForTheTileListAndClearedByACleanRead() async throws {
        let defaults = UserDefaults(suiteName: "github-diagnosis-\(UUID().uuidString)")!
        let diagnoses = UserDefaultsGitHubDiagnoses(defaults: defaults)
        let failing = GitHubConnector(
            tile: record(GitHubTileConfig(repo: "a/x")),
            source: FixedSource { throw GitHubAPI.Failure.status(401) },
            snapshots: Snapshots(), diagnoses: diagnoses
        )
        _ = try await failing.read()
        #expect(diagnoses.diagnosis(for: failing.tile)
            == GitHubDiagnosis(message: "GitHub refused the token (401) — paste a new one", isQuiet: false))

        let clean = GitHubConnector(
            tile: record(GitHubTileConfig(repo: "a/x")),
            source: FixedSource { GitHubRepoState(nameWithOwner: "a/x", stars: 1, forks: 0, openPRs: 0) },
            snapshots: Snapshots(), diagnoses: diagnoses
        )
        _ = try await clean.read()
        #expect(diagnoses.diagnosis(for: clean.tile) == nil)
    }
}

// MARK: - Partial answers

@Suite struct GitHubPartialAnswerTests {
    @Test func aStargazersOnlyRefusalKeepsTheCounts() throws {
        let state = try GitHubAPI.decode(
            body(repository: repository(stargazers: "null"), errors: refusedStargazers), repo: "a/x"
        )
        #expect(state.stars == 12)
        #expect(state.forks == 3)
        #expect(state.openPRs == 1)
        #expect(state.openPRNumbers == [OpenPR(number: 7, author: "dave")])
        #expect(state.stargazers.isEmpty)
        #expect(state.stargazersRefused)
    }

    @Test func aFullAnswerIsNotRefused() throws {
        let state = try GitHubAPI.decode(
            body(repository: repository(stargazers: #"{"edges":[]}"#), errors: nil), repo: "a/x"
        )
        #expect(state.stargazersRefused == false)
    }

    /// The live answer for the user's read-only token on a public repository
    /// (artk0de/TeaRAGs-MCP, 2026-09-24): every field reads except
    /// `repository.stargazers`. The tile works, and says so quietly.
    @Test func theLiveReadOnlyAnswerIsQuiet() throws {
        let state = try GitHubAPI.decode(
            body(repository: repository(stargazers: "null"), errors: refusedStargazers), repo: "a/x"
        )
        let reading = GitHubReading(content: .state(state), config: GitHubTileConfig(repo: "a/x"))
        #expect(reading.diagnosis == GitHubDiagnosis(
            message: "Who starred needs Contents: write — stars are counted instead", isQuiet: true
        ))
    }

    /// Any other forbidden field is that part absent: the rest is kept and
    /// the permission named.
    @Test func aForbiddenFieldNamesThePermissionItWants() throws {
        let cases: [([String], GitHubWithheld, String)] = [
            (["repository", "openPRs"], .pullRequests, "Token lacks Pull requests: read"),
            (["repository", "pullRequests"], .pullRequests, "Token lacks Pull requests: read"),
            (["repository", "defaultBranchRef", "target", "statusCheckRollup"], .checks,
             "Token lacks Commit statuses: read and Checks: read"),
            (["repository", "defaultBranchRef", "target", "author"], .contents, "Token lacks Contents: read"),
            (["repository", "forks"], .metadata, "Token lacks Metadata: read"),
            (["repository", "forkCount"], .metadata, "Token lacks Metadata: read"),
            (["repository", "watchers"], .other("repository.watchers"),
             "Token lacks a permission for repository.watchers"),
        ]
        for (path, part, sentence) in cases {
            let pathJSON = "[" + path.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            let errors = #"[{"type":"FORBIDDEN","path":\#(pathJSON),"message":"no"}]"#
            let state = try GitHubAPI.decode(
                body(repository: repository(stargazers: #"{"edges":[]}"#), errors: errors), repo: "a/x"
            )
            #expect(state.withheld == [part], "\(path)")
            #expect(state.stars == 12, "\(path)")
            let reading = GitHubReading(content: .state(state), config: GitHubTileConfig(repo: "a/x"))
            #expect(reading.diagnosis == GitHubDiagnosis(message: sentence, isQuiet: false), "\(path)")
        }
    }

    /// A withheld part is hidden on the TC002 ticker, not drawn as a zero.
    @Test func aWithheldCountLeavesTheTicker() {
        let config = GitHubTileConfig(repo: "a/x")
        var state = GitHubRepoState(nameWithOwner: "a/x", stars: 12, forks: 3, openPRs: 0)
        state.withheld = [.pullRequests]
        var hidden = config
        hidden.showPRs = false
        #expect(GitHubFace.timeline(ambient: state, noToken: false, config: config)
            == GitHubFace.timeline(ambient: state, noToken: false, config: hidden))
    }

    /// Withheld PRs are not "every PR closed": the set is kept, and the
    /// permission granted back replays nothing.
    @Test func withheldPRsDoNotMoveTheSnapshot() {
        let open = GitHubRepoState(
            nameWithOwner: "a/x", stars: 1, forks: 0, openPRs: 1, openPRNumbers: [OpenPR(number: 5, author: "d")]
        )
        let (_, snapshot) = GitHubEventDetector.detect(open, since: nil)
        var blind = GitHubRepoState(nameWithOwner: "a/x", stars: 1, forks: 0, openPRs: 0)
        blind.withheld = [.pullRequests]
        let (none, kept) = GitHubEventDetector.detect(blind, since: snapshot)
        #expect(none.isEmpty)
        #expect(kept.openPRs == [5])
        let (again, _) = GitHubEventDetector.detect(open, since: kept)
        #expect(again.isEmpty)
    }

    @Test func anyOtherErrorBesideDataIsAFailure() throws {
        let mixed = """
        [{"type":"FORBIDDEN","path":["repository","stargazers"],"message":"stars"},
         {"type":"INTERNAL","path":["repository","openPRs"],"message":"other"}]
        """
        #expect(throws: (any Error).self) {
            _ = try GitHubAPI.decode(body(repository: repository(stargazers: "null"), errors: mixed), repo: "a/x")
        }
    }

    @Test func aRefusalWithoutARepositoryIsAFailure() throws {
        #expect(throws: (any Error).self) {
            _ = try GitHubAPI.decode(body(repository: nil, errors: refusedStargazers), repo: "a/x")
        }
    }

    /// The normal path for a read-only fine-grained token: listing
    /// stargazers needs Contents: write, so the preview names the permission
    /// and says the stars are counted.
    @Test func thePreviewSaysStarsAreCountedNotNamed() {
        var state = GitHubRepoState(nameWithOwner: "a/x", stars: 12, forks: 3, openPRs: 1)
        state.stargazersRefused = true
        let reading = GitHubReading(content: .state(state), config: GitHubTileConfig(repo: "a/x"))
        #expect(reading.previewNote == "Who starred needs Contents: write — stars are counted instead")
    }

    /// A rise celebrates by count, with no logins to name.
    @Test func aStarRiseWithoutLoginsCelebratesByCount() {
        var blind = GitHubRepoState(nameWithOwner: "a/x", stars: 12, forks: 3, openPRs: 0)
        blind.stargazersRefused = true
        let (baseline, snapshot) = GitHubEventDetector.detect(blind, since: nil)
        #expect(baseline.isEmpty)

        blind.stars = 14
        let (events, _) = GitHubEventDetector.detect(blind, since: snapshot)
        #expect(events.newStarCount == 2)
        #expect(events.newStars.isEmpty)
    }

    /// The permission granted later: the page's stargazers appear with no
    /// timestamp to compare against, and only the rise since the last read is
    /// news — the stars already there are not celebrated again.
    @Test func grantingThePermissionLaterReplaysNothing() {
        var blind = GitHubRepoState(nameWithOwner: "a/x", stars: 3, forks: 0, openPRs: 0)
        blind.stargazersRefused = true
        let (_, snapshot) = GitHubEventDetector.detect(blind, since: nil)

        let seen = GitHubRepoState(
            nameWithOwner: "a/x", stars: 3, forks: 0, openPRs: 0,
            stargazers: (0..<3).map { Stargazer(login: "old\($0)", starredAt: moment.addingTimeInterval(Double($0))) }
        )
        let (quiet, next) = GitHubEventDetector.detect(seen, since: snapshot)
        #expect(quiet.isEmpty)
        #expect(next.lastStarAt == moment.addingTimeInterval(2))

        var risen = GitHubRepoState(
            nameWithOwner: "a/x", stars: 4, forks: 0, openPRs: 0,
            stargazers: seen.stargazers + [Stargazer(login: "new", starredAt: moment.addingTimeInterval(60))]
        )
        risen.stargazersRefused = false
        let (events, _) = GitHubEventDetector.detect(risen, since: next)
        #expect(events.newStars == ["new"])
        #expect(events.newStarCount == 1)
    }

    /// Granted in the same interval a star arrived: the rise names the
    /// newest of the page, and no more.
    @Test func grantingThePermissionWithARiseNamesOnlyTheRise() {
        var blind = GitHubRepoState(nameWithOwner: "a/x", stars: 2, forks: 0, openPRs: 0)
        blind.stargazersRefused = true
        let (_, snapshot) = GitHubEventDetector.detect(blind, since: nil)

        let seen = GitHubRepoState(
            nameWithOwner: "a/x", stars: 3, forks: 0, openPRs: 0,
            stargazers: [
                Stargazer(login: "a", starredAt: moment),
                Stargazer(login: "b", starredAt: moment.addingTimeInterval(1)),
                Stargazer(login: "c", starredAt: moment.addingTimeInterval(2)),
            ]
        )
        let (events, _) = GitHubEventDetector.detect(seen, since: snapshot)
        #expect(events.newStars == ["c"])
        #expect(events.newStarCount == 1)
    }
}

// MARK: - Show and Notify

@Suite struct GitHubTogglesTests {
    private let state = GitHubRepoState(
        nameWithOwner: "artk0de/tea-rags", stars: 1234, forks: 45, openPRs: 3,
        ci: GitHubCI(state: .failure, branch: "main", headOid: "a1", author: "dave")
    )

    @Test func everyToggleIsOnByDefault() {
        let config = GitHubTileConfig(repo: "a/x")
        #expect(config.showForks && config.showPRs && config.showCI)
        #expect(config.notifyStars && config.notifyForks && config.notifyPRs && config.notifyCI)
    }

    /// A record written before the toggles existed reads them on.
    @Test func anOlderRecordDecodesWithEveryToggleOn() throws {
        let old = Data(#"{"repo":"a/x","shortName":"ax","celebrationSeconds":10}"#.utf8)
        let config = try JSONDecoder().decode(GitHubTileConfig.self, from: old)
        #expect(config == GitHubTileConfig(repo: "a/x", shortName: "ax", celebrationSeconds: 10))
    }

    @Test func theTogglesRoundTrip() throws {
        var config = GitHubTileConfig(repo: "a/x")
        config.showForks = false
        config.showCI = false
        config.notifyPRs = false
        let decoded = try JSONDecoder().decode(GitHubTileConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    /// Show filters the TC002 ambient: the page is ggen's for the same
    /// toggles (the oracle cases a16–a18 hold the pixels), and differs from
    /// the default page.
    @Test func showTogglesReachTheTC002Page() {
        var hidden = GitHubTileConfig(repo: "artk0de/tea-rags")
        hidden.showForks = false
        hidden.showCI = false
        let delivery = GitHubFace.delivery(for: GitHubReading(content: .state(state), config: hidden))
        let frames = GitHubFace.timeline(ambient: state, noToken: false, config: hidden)
        #expect(delivery.scene == GitHubFace.scene(frames))
        #expect(frames != GitHubFace.timeline(ambient: state, noToken: false, config: GitHubTileConfig(repo: "a/x")))
    }

    /// Notify off drops the event on both models; the snapshot still
    /// advances, so turning it back on replays nothing.
    @Test func notifyOffDropsTheEventAndTheSnapshotStillAdvances() async throws {
        let snapshots = Snapshots()
        var config = GitHubTileConfig(repo: "a/x")
        config.notifyStars = false
        config.notifyCI = false
        let old = Stargazer(login: "bob", starredAt: moment)
        let new = Stargazer(login: "alice", starredAt: moment.addingTimeInterval(60))
        let first = GitHubRepoState(nameWithOwner: "a/x", stars: 1, forks: 0, openPRs: 0, stargazers: [old])
        let second = GitHubRepoState(
            nameWithOwner: "a/x", stars: 2, forks: 0, openPRs: 1, stargazers: [old, new],
            openPRNumbers: [OpenPR(number: 9, author: "dave")],
            ci: GitHubCI(state: .failure, branch: "main", headOid: "b2", author: "dave")
        )
        let answers = Answers([first, second])
        let subject = GitHubConnector(
            tile: record(config), source: FixedSource { answers.next() }, snapshots: snapshots
        )

        _ = try await subject.read()
        let reading = try await subject.read()

        #expect(reading.events.newStars.isEmpty)
        #expect(reading.events.newStarCount == 0)
        #expect(reading.events.ciFailure == nil)
        #expect(reading.events.newPRs == [OpenPR(number: 9, author: "dave")])
        #expect(snapshots.snapshot(for: subject.tile)?.lastStarAt == new.starredAt)
        #expect(snapshots.snapshot(for: subject.tile)?.lastFailedOid == "b2")
        // Neither face has anything of the stars or the CI to show.
        #expect(GitHubFace.delivery(for: reading).interruptions.count == 1)
        #expect(GitHubAwtrixFace.draw(reading, appName: "g").interruptions.map(\.scene.text) == ["PR #9 @dave"])
    }

    @Test func notifyOffForForksAndPRsDropsThem() {
        var events = GitHubEvents()
        events.newStars = ["alice"]
        events.newStarCount = 1
        events.newForks = ["carol"]
        events.newForkCount = 1
        events.newPRs = [OpenPR(number: 4, author: "dave")]
        var config = GitHubTileConfig(repo: "a/x")
        config.notifyForks = false
        config.notifyPRs = false

        let kept = events.notifying(config)

        #expect(kept.newStars == ["alice"] && kept.newStarCount == 1)
        #expect(kept.newForks.isEmpty && kept.newForkCount == 0)
        #expect(kept.newPRs.isEmpty)
    }
}

/// Hands out states in order; the last repeats.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [GitHubRepoState]

    init(_ states: [GitHubRepoState]) { self.states = states }

    func next() -> GitHubRepoState {
        lock.withLock { states.count > 1 ? states.removeFirst() : states[0] }
    }
}
