// Tests/PixelClockKitTests/GitHubAwtrixFaceTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The TC001 face: the repository as an app in the clock's loop, and each kind
// of arrival as a notification that plays its jingle on the buzzer. Posed as
// readings, so nothing here reaches a network or a clock.

private struct NoSource: GitHubReporting {
    func state(of repo: String) async throws -> GitHubRepoState? { nil }
}

private struct NoSnapshots: GitHubSnapshotStoring {
    func snapshot(for tile: TileKey) -> GitHubSnapshot? { nil }
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {}
}

private let clockId = UUID(uuidString: "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F")!
private let config = GitHubTileConfig(repo: "a/x", celebrationSeconds: 10)
private let state = GitHubRepoState(nameWithOwner: "a/x", stars: 1234, forks: 56, openPRs: 7)

private func reading(_ events: GitHubEvents = GitHubEvents()) -> GitHubReading {
    GitHubReading(content: .state(state), events: events, config: config)
}

private func draw(_ reading: GitHubReading) -> AwtrixDelivery {
    GitHubAwtrixFace.draw(reading, appName: "github-a-x-000000")
}

@Suite struct GitHubAwtrixFaceTests {
    // The app is named by the tile's wire-safe id, not by `owner/name`: the
    // name goes into `/api/custom?name=`, where a '/' cannot, and two
    // repositories on one clock are two apps.
    @Test func ambientIsAnAppNamedByTheTile() throws {
        let record = TileRecord(
            key: TileKey(clockId: clockId, connectorId: GitHubConnector.connectorId, instance: "a/x"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
            config: .github(config)
        )
        let connector = GitHubConnector(tile: record, source: NoSource(), snapshots: NoSnapshots())

        let delivery = connector.awtrixFace.draw(reading())

        #expect(delivery.surface == .app(record.key.tileId))
        #expect(delivery.text == "1234")
        #expect(delivery.icon == .bundled(GitHubAwtrixFace.icon))
        #expect(delivery.color == "#FFD84A")
        #expect(delivery.interruptions.isEmpty)
    }

    // The count is the TC002 hero's: exact to 9 999, then thousands.
    @Test func ambientCompactsTheStarsAsTheTC002HeroDoes() {
        var big = state
        big.stars = 12_345
        let delivery = draw(GitHubReading(content: .state(big), config: config))
        #expect(delivery.text == "12k")
    }

    @Test func starsInterruptWithTheCoin() throws {
        var events = GitHubEvents()
        events.newStars = ["alice", "bob"]
        events.newStarCount = 2

        let delivery = draw(reading(events))

        let interruption = try #require(delivery.interruptions.first)
        #expect(delivery.interruptions.count == 1)
        #expect(interruption.scene.surface == .notification)
        #expect(interruption.scene.text == "stars +2 @alice +1 more")
        #expect(interruption.scene.jingle == GitHubJingle.star)
        #expect(interruption.scene.duration == 10)
        #expect(interruption.scene.icon == .bundled(GitHubAwtrixFace.icon))
        #expect(interruption.scene.color == "#FFD84A")
        #expect(interruption.duration == 10)
    }

    // A burst past the page's twenty logins still counts all of it.
    @Test func aBurstCountsPastTheNamedLogins() throws {
        var events = GitHubEvents()
        events.newStars = ["alice"]
        events.newStarCount = 25

        let delivery = draw(reading(events))

        #expect(delivery.interruptions.map(\.scene.text) == ["stars +25 @alice"])
    }

    @Test func aForkUsesTheOneUp() throws {
        var events = GitHubEvents()
        events.newForks = ["carol"]
        events.newForkCount = 1

        let interruption = try #require(draw(reading(events)).interruptions.first)

        #expect(interruption.scene.text == "fork +1 @carol")
        #expect(interruption.scene.jingle == GitHubJingle.fork)
        #expect(interruption.scene.color == "#58A6FF")
        #expect(interruption.scene.surface == .notification)
    }

    @Test func aPRUsesThePowerUp() throws {
        var events = GitHubEvents()
        events.newPRs = [OpenPR(number: 42, author: "dave")]

        let interruption = try #require(draw(reading(events)).interruptions.first)

        #expect(interruption.scene.text == "PR #42 @dave")
        #expect(interruption.scene.jingle == GitHubJingle.pr)
        #expect(interruption.scene.color == "#3FB950")
    }

    @Test func severalPRsAreCountedNotNumbered() throws {
        var events = GitHubEvents()
        events.newPRs = [OpenPR(number: 44, author: "erin"), OpenPR(number: 43, author: "dave")]

        let interruption = try #require(draw(reading(events)).interruptions.first)

        #expect(interruption.scene.text == "PRs +2 @erin +1 more")
    }

    // One read that brings stars AND a fork carries both, stars first — the
    // clock queues notifications, so this order is the order they play.
    @Test func starsAndAForkInOneReadAreTwoNotificationsInOrder() {
        var events = GitHubEvents()
        events.newStars = ["alice"]
        events.newStarCount = 1
        events.newForks = ["carol"]
        events.newForkCount = 1
        events.newPRs = [OpenPR(number: 42, author: "dave")]

        let delivery = draw(reading(events))

        #expect(delivery.interruptions.map(\.scene.text) == ["star +1 @alice", "fork +1 @carol", "PR #42 @dave"])
        #expect(delivery.interruptions.map(\.scene.jingle) == [GitHubJingle.star, GitHubJingle.fork, GitHubJingle.pr])
        #expect(delivery.interruptions.allSatisfy { $0.scene.surface == .notification })
    }

    @Test func noTokenAndNoDataShowTheirWords() {
        for (content, words) in [(GitHubReading.Content.noToken, "no token"), (.noData, "no data")] {
            let delivery = draw(GitHubReading(content: content, config: config))
            #expect(delivery.text == words)
            #expect(delivery.surface == .app("github-a-x-000000"))
            #expect(delivery.icon == .bundled(GitHubAwtrixFace.icon))
            #expect(delivery.interruptions.isEmpty)
        }
    }

    // The icon is `.bundled`, which promises the art is inside the app: it
    // must ship, as an animated-capable GIF89a, at the 8×8 an icon gets.
    @Test func theIconShipsAsAnEightByEightGIF() throws {
        let blob = try #require(BundledIcon.data(named: GitHubAwtrixFace.icon))
        #expect(blob.starts(with: Data("GIF89a".utf8)))
        #expect(Int(blob[6]) | Int(blob[7]) << 8 == 8)
        #expect(Int(blob[8]) | Int(blob[9]) << 8 == 8)
    }

    // The kit has no RTTTL parser — the buzzer is the only reader — so the
    // shape is held here: `name:d=N,o=N,b=N:notes`, a name the firmware
    // takes (≤ 10 characters), every note `[duration]pitch[#][.][octave][.]`,
    // and short enough to stay a jingle.
    // A failing default branch rings after the arrivals, in GitHub's failure
    // red, naming the branch and the commit's author.
    @Test func aFailingBranchRingsLast() throws {
        var events = GitHubEvents()
        events.newStars = ["alice"]
        events.newStarCount = 1
        events.ciFailure = GitHubCIFailure(branch: "main", author: "dave", oid: "b2")

        let delivery = draw(reading(events))

        #expect(delivery.interruptions.map(\.scene.text) == ["star +1 @alice", "CI fail main @dave"])
        let ci = try #require(delivery.interruptions.last)
        #expect(ci.scene.jingle == GitHubJingle.ciFailure)
        #expect(ci.scene.color == "#F85149")
        #expect(ci.scene.icon == .bundled(GitHubAwtrixFace.icon))
        #expect(ci.scene.surface == .notification)
        #expect(ci.scene.duration == 10)
        #expect(ci.duration == 10)
    }

    @Test func aFailureWithoutAnAuthorNamesOnlyTheBranch() throws {
        var events = GitHubEvents()
        events.ciFailure = GitHubCIFailure(branch: "develop", author: nil, oid: "b2")

        #expect(draw(reading(events)).interruptions.map(\.scene.text) == ["CI fail develop"])
    }

    // The TC001 has no lamp: its app is one text line, and a pending or red
    // branch leaves it as it is.
    @Test func noLampOnTheApp() {
        var red = state
        red.ci = GitHubCI(state: .failure, branch: "main", headOid: "b2", author: "dave")
        let delivery = draw(GitHubReading(content: .state(red), config: config))
        #expect(delivery == draw(reading()))
    }

    @Test(arguments: [GitHubJingle.star, GitHubJingle.fork, GitHubJingle.pr, GitHubJingle.ciFailure])
    func eachJingleIsWellFormedRTTTL(_ tune: String) throws {
        let sections = tune.split(separator: ":", omittingEmptySubsequences: false)
        try #require(sections.count == 3)
        #expect((1...10).contains(sections[0].count))
        #expect(sections[1].wholeMatch(of: /d=(1|2|4|8|16|32),o=[4-7],b=\d{2,3}/) != nil)
        let notes = sections[2].split(separator: ",", omittingEmptySubsequences: false)
        #expect((1...12).contains(notes.count))
        for note in notes {
            #expect(note.wholeMatch(of: /(1|2|4|8|16|32)?([a-g]#?|p)\.?[4-7]?\.?/) != nil, "\(note)")
        }
    }
}
