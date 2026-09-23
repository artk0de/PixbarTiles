// Tests/PixelClockKitTests/GitHubEventsTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The detector is pure: a state and the last snapshot in, the events and the
// next snapshot out. Events are found by identity — a timestamp newer than
// the last seen, a PR number not seen before — so a count that did not move
// can still hide a star, and a count that moved further than the page reaches
// still counts every star.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let t1 = t0.addingTimeInterval(60)
private let t2 = t0.addingTimeInterval(120)
private let t3 = t0.addingTimeInterval(180)

/// A state whose counts default to what its lists hold, the way a small
/// repository's would.
private func state(
    stars: [(String, Date)] = [], forks: [(String, Date)] = [], prs: [(Int, String)] = [],
    starTotal: Int? = nil, forkTotal: Int? = nil
) -> GitHubRepoState {
    GitHubRepoState(
        nameWithOwner: "artk0de/tea-rags",
        stars: starTotal ?? stars.count,
        forks: forkTotal ?? forks.count,
        openPRs: prs.count,
        stargazers: stars.map { Stargazer(login: $0.0, starredAt: $0.1) },
        forkEvents: forks.map { ForkEvent(login: $0.0, createdAt: $0.1) },
        openPRNumbers: prs.map { OpenPR(number: $0.0, author: $0.1) }
    )
}

@Suite struct GitHubEventsTests {
    @Test func theFirstReadIsABaselineAndCelebratesNothing() {
        let (events, snap) = GitHubEventDetector.detect(state(stars: [("a", t0)]), since: nil)
        #expect(events.isEmpty)
        #expect(snap.lastStarAt == t0)
    }

    @Test func starsNewerThanTheLastSeenAreNewAndNewestFirst() {
        let (events, _) = GitHubEventDetector.detect(
            state(stars: [("a", t0), ("b", t1), ("c", t2)]),
            since: GitHubSnapshot(lastStarAt: t0, lastForkAt: nil, openPRs: [])
        )
        #expect(events.newStars == ["c", "b"])
        #expect(events.newStarCount == 2)
    }

    @Test func anUnstarAndAStarInOneIntervalStillCelebratesTheStar() {
        // "a" and "b" were there; "a" unstarred and "c" starred. The total
        // did not move, so a count delta would see nothing.
        let (events, snap) = GitHubEventDetector.detect(
            state(stars: [("b", t1), ("c", t2)]),
            since: GitHubSnapshot(lastStarAt: t1, lastForkAt: nil, openPRs: [], stars: 2, forks: 0)
        )
        #expect(events.newStars == ["c"])
        #expect(events.newStarCount == 1)
        #expect(snap.lastStarAt == t2)
    }

    @Test func moreStarsThanThePageHoldsAreStillCounted() {
        // 25 arrived since the snapshot; the page carries only the newest 10.
        let page = (0..<10).map { ("s\($0)", t1.addingTimeInterval(Double($0))) }
        let (events, snap) = GitHubEventDetector.detect(
            state(stars: page, starTotal: 125),
            since: GitHubSnapshot(lastStarAt: t0, lastForkAt: nil, openPRs: [], stars: 100, forks: 0)
        )
        #expect(events.newStarCount == 25)
        #expect(events.newStars.count == 10)
        #expect(events.newStars.first == "s9")
        #expect(snap.stars == 125)
    }

    @Test func aTotalThatDroppedDoesNotHideAPageDetectedStar() {
        // Two unstars and one star: the total fell by one, the page still
        // shows one starredAt newer than the last seen.
        let (events, _) = GitHubEventDetector.detect(
            state(stars: [("a", t0), ("b", t2)], starTotal: 9),
            since: GitHubSnapshot(lastStarAt: t1, lastForkAt: nil, openPRs: [], stars: 10, forks: 0)
        )
        #expect(events.newStarCount == 1)
        #expect(events.newStars == ["b"])
    }

    @Test func aSnapshotWithoutTotalsFallsBackToThePageCount() throws {
        // A snapshot encoded before the totals were remembered.
        let old = Data(#"{"openPRs":[],"lastStarAt":\#(t0.timeIntervalSinceReferenceDate)}"#.utf8)
        let snapshot = try JSONDecoder().decode(GitHubSnapshot.self, from: old)
        #expect(snapshot.stars == nil)

        let (events, snap) = GitHubEventDetector.detect(
            state(stars: [("a", t0), ("b", t1)], starTotal: 50), since: snapshot
        )
        #expect(events.newStarCount == 1)
        #expect(events.newStars == ["b"])
        #expect(snap.stars == 50)
    }

    @Test func aCountWithoutLoginsIsNotEmpty() {
        var events = GitHubEvents()
        #expect(events.isEmpty)
        events.newForkCount = 3
        #expect(!events.isEmpty)
    }

    @Test func aPROpenedAndAnotherMergedCelebratesTheOpenedOne() {
        let (events, snap) = GitHubEventDetector.detect(
            state(prs: [(42, "dave")]),
            since: GitHubSnapshot(lastStarAt: nil, lastForkAt: nil, openPRs: [41])
        )
        #expect(events.newPRs == [OpenPR(number: 42, author: "dave")])
        #expect(snap.openPRs == [42])
    }

    @Test func newPRsAreNewestFirst() {
        let (events, _) = GitHubEventDetector.detect(
            state(prs: [(40, "x"), (43, "y"), (44, "z")]),
            since: GitHubSnapshot(lastStarAt: nil, lastForkAt: nil, openPRs: [40])
        )
        #expect(events.newPRs.map(\.number) == [44, 43])
    }

    @Test func aClosedPRIsNotAnEvent() {
        let (events, snap) = GitHubEventDetector.detect(
            state(prs: [(42, "dave")]),
            since: GitHubSnapshot(lastStarAt: nil, lastForkAt: nil, openPRs: [41, 42])
        )
        #expect(events.isEmpty)
        #expect(snap.openPRs == [42])
    }

    @Test func anOlderPRSlidingIntoThePageIsNotNew() {
        // More than 20 open: the page is the newest 20. #49 merged, so #29 —
        // open all along — slides into the page without being new.
        let (events, snap) = GitHubEventDetector.detect(
            state(prs: (29...48).map { ($0, "u\($0)") }),
            since: GitHubSnapshot(
                lastStarAt: nil, lastForkAt: nil, openPRs: Set(30...49), lastPRNumber: 49
            )
        )
        #expect(events.newPRs.isEmpty)
        #expect(events.isEmpty)
        #expect(snap.lastPRNumber == 49)
    }

    @Test func aPROpenedWhileAnotherSlidesInIsTheOnlyNewOne() {
        let (events, snap) = GitHubEventDetector.detect(
            state(prs: ([29] + Array(31...48) + [50]).map { ($0, "u\($0)") }),
            since: GitHubSnapshot(
                lastStarAt: nil, lastForkAt: nil, openPRs: Set(30...49), lastPRNumber: 49
            )
        )
        #expect(events.newPRs == [OpenPR(number: 50, author: "u50")])
        #expect(snap.lastPRNumber == 50)
    }

    @Test func aSnapshotWithoutLastPRNumberFallsBackToTheSet() throws {
        // A snapshot encoded before the highest number was remembered.
        let old = Data(#"{"openPRs":[41]}"#.utf8)
        let snapshot = try JSONDecoder().decode(GitHubSnapshot.self, from: old)
        #expect(snapshot.lastPRNumber == nil)

        let (events, snap) = GitHubEventDetector.detect(
            state(prs: [(40, "x"), (42, "y")]), since: snapshot
        )
        #expect(events.newPRs.map(\.number) == [42, 40])
        #expect(snap.lastPRNumber == 42)
    }

    @Test func forksByCreatedAt() {
        let (events, snap) = GitHubEventDetector.detect(
            state(forks: [("x", t0), ("y", t1), ("z", t2)]),
            since: GitHubSnapshot(lastStarAt: nil, lastForkAt: t0, openPRs: [])
        )
        #expect(events.newForks == ["z", "y"])
        #expect(events.newForkCount == 2)
        #expect(snap.lastForkAt == t2)
    }

    @Test func theSnapshotNeverMovesBackward() {
        // Every newer star unstarred: the page's newest is older than the
        // last seen, and the snapshot keeps what it had.
        let (events, snap) = GitHubEventDetector.detect(
            state(stars: [("a", t0)]),
            since: GitHubSnapshot(lastStarAt: t3, lastForkAt: nil, openPRs: [])
        )
        #expect(events.isEmpty)
        #expect(snap.lastStarAt == t3)
    }

    @Test func theSnapshotSurvivesTheStore() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserDefaultsGitHubSnapshots(defaults: d)
        let key = TileKey(clockId: UUID(), connectorId: "github", instance: "a/x")
        store.save(GitHubSnapshot(lastStarAt: t1, lastForkAt: nil, openPRs: [7]), for: key)
        #expect(store.snapshot(for: key)?.openPRs == [7])
        #expect(store.snapshot(for: key)?.lastStarAt == t1)
    }

    @Test func eachTileKeepsItsOwnSnapshot() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserDefaultsGitHubSnapshots(defaults: d)
        let clock = UUID()
        let a = TileKey(clockId: clock, connectorId: "github", instance: "a/x")
        let b = TileKey(clockId: clock, connectorId: "github", instance: "a/y")
        store.save(GitHubSnapshot(lastStarAt: nil, lastForkAt: nil, openPRs: [1]), for: a)

        #expect(store.snapshot(for: b) == nil)
        #expect(d.data(forKey: "githubSnapshot.\(a.tileId).\(clock.uuidString)") != nil)
    }
}

// The default branch's CI: a failure is news once per failing head commit.
// The snapshot remembers the last failing head, so a relaunch, a later read of
// the same commit, or a re-run that fails again never celebrates twice.

private func ciState(_ state: GitHubCI.State, oid: String, author: String? = "dave") -> GitHubRepoState {
    var repo = GitHubRepoState(nameWithOwner: "artk0de/tea-rags", stars: 0, forks: 0, openPRs: 0)
    repo.ci = GitHubCI(state: state, branch: "main", headOid: oid, author: author)
    return repo
}

private let quiet = GitHubSnapshot(lastStarAt: nil, lastForkAt: nil, openPRs: [])

@Suite struct GitHubCIEventTests {
    @Test func aFailingHeadAfterAGreenOneIsAnEvent() {
        let (_, green) = GitHubEventDetector.detect(ciState(.success, oid: "a1"), since: quiet)
        let (events, snap) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: green)
        #expect(events.ciFailure == GitHubCIFailure(branch: "main", author: "dave", oid: "b2"))
        #expect(!events.isEmpty)
        #expect(snap.lastFailedOid == "b2")
    }

    @Test func aBaselineWithAFailingHeadIsNoEventButIsRemembered() {
        let (events, snap) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: nil)
        #expect(events.ciFailure == nil)
        #expect(events.isEmpty)
        #expect(snap.lastFailedOid == "b2")
        // …so the next read of the same commit does not celebrate it either.
        let (again, _) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: snap)
        #expect(again.ciFailure == nil)
    }

    @Test func theSameFailingCommitNeverCelebratesTwice() {
        let (first, snap) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: quiet)
        #expect(first.ciFailure != nil)
        let (second, snap2) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: snap)
        #expect(second.ciFailure == nil)
        #expect(second.isEmpty)
        #expect(snap2.lastFailedOid == "b2")
    }

    @Test func theRememberedFailureSurvivesARelaunch() throws {
        let (_, snap) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: quiet)
        let relaunched = try JSONDecoder().decode(GitHubSnapshot.self, from: JSONEncoder().encode(snap))
        let (events, _) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: relaunched)
        #expect(events.ciFailure == nil)
    }

    @Test func pendingThenFailureOnTheSameCommitIsOneEvent() {
        let (pending, snap) = GitHubEventDetector.detect(ciState(.pending, oid: "b2"), since: quiet)
        #expect(pending.ciFailure == nil)
        #expect(snap.lastFailedOid == nil)
        let (failed, snap2) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: snap)
        #expect(failed.ciFailure?.oid == "b2")
        let (after, _) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: snap2)
        #expect(after.ciFailure == nil)
    }

    @Test func aNewFailingCommitAfterAnEarlierFailingOneIsAnEvent() {
        let (_, snap) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: quiet)
        let (events, snap2) = GitHubEventDetector.detect(ciState(.failure, oid: "c3", author: nil), since: snap)
        #expect(events.ciFailure == GitHubCIFailure(branch: "main", author: nil, oid: "c3"))
        #expect(snap2.lastFailedOid == "c3")
    }

    @Test func greenPendingAndNoChecksAreNoEvents() {
        for state in [GitHubCI.State.success, .pending, .none] {
            let (events, _) = GitHubEventDetector.detect(ciState(state, oid: "b2"), since: quiet)
            #expect(events.ciFailure == nil, "\(state)")
        }
        let (events, _) = GitHubEventDetector.detect(state(), since: quiet)
        #expect(events.ciFailure == nil)
    }

    /// A green read keeps the last failure: a re-run that fails the same
    /// commit again is not news.
    @Test func aGreenReadKeepsTheLastFailure() {
        let (_, snap) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: quiet)
        let (_, green) = GitHubEventDetector.detect(ciState(.success, oid: "b2"), since: snap)
        #expect(green.lastFailedOid == "b2")
        let (events, _) = GitHubEventDetector.detect(ciState(.failure, oid: "b2"), since: green)
        #expect(events.ciFailure == nil)
    }

    @Test func aSnapshotWithoutALastFailureDecodes() throws {
        let old = Data(#"{"openPRs":[41]}"#.utf8)
        let snapshot = try JSONDecoder().decode(GitHubSnapshot.self, from: old)
        #expect(snapshot.lastFailedOid == nil)
    }
}
