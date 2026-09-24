// Tests/PixbarKitTests/GitHubMainWatchTests.swift
import Foundation
import Testing
@testable import PixbarKit

// The Main watch: which metric holds the hero — the stars (as shipped), the
// open PRs, the forks, or the default branch's CI. The TC002 pixels are the
// oracle's (cases a19–a26); these hold the setting and the TC001 line.

private let state = GitHubRepoState(
    nameWithOwner: "artk0de/tea-rags", stars: 1234, forks: 12_345, openPRs: 7,
    ci: GitHubCI(state: .success, branch: "main", headOid: "a1", author: "dave")
)

private func config(_ watch: GitHubMainWatch) -> GitHubTileConfig {
    var config = GitHubTileConfig(repo: "artk0de/tea-rags")
    config.mainWatch = watch
    return config
}

private func line(_ watch: GitHubMainWatch, ci: GitHubCI.State? = .success) -> AwtrixDelivery {
    var state = state
    state.ci = ci.map { GitHubCI(state: $0, branch: "main", headOid: "a1", author: "dave") }
    return GitHubAwtrixFace.draw(GitHubReading(content: .state(state), config: config(watch)), appName: "g")
}

@Suite struct GitHubMainWatchTests {
    @Test func theStarsHoldTheHeroByDefault() {
        #expect(GitHubTileConfig(repo: "a/x").mainWatch == .stars)
        #expect(GitHubMainWatch.allCases == [.stars, .prs, .forks, .ci])
    }

    @Test func anOlderRecordReadsTheStars() throws {
        let old = Data(#"{"repo":"a/x","celebrationSeconds":8}"#.utf8)
        #expect(try JSONDecoder().decode(GitHubTileConfig.self, from: old).mainWatch == .stars)
    }

    @Test func theMainWatchRoundTrips() throws {
        for watch in GitHubMainWatch.allCases {
            let decoded = try JSONDecoder().decode(
                GitHubTileConfig.self, from: JSONEncoder().encode(config(watch))
            )
            #expect(decoded.mainWatch == watch)
        }
    }

    /// The TC002 page follows the setting: each watch draws its own page.
    @Test func eachWatchDrawsItsOwnTC002Page() {
        let pages = GitHubMainWatch.allCases.map {
            GitHubFace.delivery(for: GitHubReading(content: .state(state), config: config($0))).scene
        }
        #expect(Set(pages.map { "\($0)" }).count == GitHubMainWatch.allCases.count)
    }

    // MARK: - The TC001 line

    @Test func theTC001LineShowsTheStarsByDefault() {
        let delivery = line(.stars)
        #expect(delivery.text == "1234")
        #expect(delivery.color == "#FFD84A")
    }

    @Test func theTC001LineShowsThePRsOrTheForksInTheirColours() {
        #expect(line(.prs).text == "7")
        #expect(line(.prs).color == "#3FB950")
        #expect(line(.forks).text == "12k")
        #expect(line(.forks).color == "#58A6FF")
    }

    @Test func theTC001LineSaysTheCIInWords() {
        #expect(line(.ci, ci: .success).text == "CI passed")
        #expect(line(.ci, ci: .success).color == "#3FB950")
        #expect(line(.ci, ci: .pending).text == "CI processed")
        #expect(line(.ci, ci: .pending).color == "#D29922")
        #expect(line(.ci, ci: .failure).text == "CI failed")
        #expect(line(.ci, ci: .failure).color == "#F85149")
        #expect(line(.ci, ci: GitHubCI.State.none).text == "no CI")
        #expect(line(.ci, ci: nil).text == "no CI")
        #expect(line(.ci, ci: nil).color == GitHubAwtrixFace.quietColour)
    }
}
