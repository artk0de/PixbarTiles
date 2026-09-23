import Foundation
import Testing
@testable import PixelClockKit

// The TC002 GitHub face against the approved design: every oracle case's one
// 52x16 timeline, pixel for pixel and delay for delay, the glyph rows and
// octicon coverage it is drawn from, the ceilings, and the delivery the
// connector hands the session. The oracle is
// `Scripts/make_github_face_oracle.py` over the skill's `github/ggen.py`; a
// mismatch is a Swift bug, never a reason to re-record.

/// `github_face_oracle.json`, as these suites read it. Frames are stored as
/// `framesZ` (base64 of raw DEFLATE), the weather oracle's format and loader.
private struct GitHubOracle: Decodable {
    struct Reading: Decodable {
        let repo: String
        let stars: Int
        let forks: Int
        let prs: Int
    }

    struct Case: Decodable {
        let id: String
        let kind: String
        let dwell: Int
        let celebrate: Int
        // ambient
        let reading: Reading?
        let shortName: String?
        let token: Bool?
        // celebration
        let count: Int?
        let who: [String]?
        let prNumbers: [Int]?
        let frameCount: Int
        let framesZ: String

        func frames() throws -> [WeatherOracle.Frame] {
            try JSONDecoder().decode([WeatherOracle.Frame].self, from: WeatherOracle.inflate(framesZ))
        }
    }

    let glyphs: [String: [String: [String]]]
    let octicons: [String: [String]]
    let cases: [Case]

    static func load() throws -> GitHubOracle {
        let url = try #require(Bundle.module.url(forResource: "github_face_oracle", withExtension: "json"))
        return try JSONDecoder().decode(GitHubOracle.self, from: Data(contentsOf: url))
    }
}

/// The Swift face's timeline for an oracle case's input.
private func drawn(_ c: GitHubOracle.Case) throws -> [GitHubFace.Frame] {
    if c.kind == "ambient" {
        let state = c.reading.map {
            GitHubRepoState(nameWithOwner: $0.repo, stars: $0.stars, forks: $0.forks, openPRs: $0.prs)
        }
        let config = GitHubTileConfig(repo: c.reading?.repo ?? "", shortName: c.shortName)
        return GitHubFace.timeline(
            ambient: state, noToken: c.token == false, config: config, dwellMilliseconds: c.dwell
        )
    }
    let kind = try #require(GitHubEventKind(rawValue: c.kind), "\(c.id) kind")
    return GitHubFace.celebration(
        kind: kind, count: try #require(c.count), who: c.who ?? [], prNumbers: c.prNumbers ?? [],
        celebrateMilliseconds: c.celebrate
    )
}

private func gif(_ frames: [GitHubFace.Frame]) throws -> Data {
    try FullFrameGif.encode(
        frames: frames.map(\.canvas), delays: frames.map { TimeInterval($0.milliseconds) / 1000 }
    )
}

@Suite struct GitHubFaceOracleTests {
    @Test func everyCaseReproducesTheApprovedFramesExactly() throws {
        let oracle = try GitHubOracle.load()
        #expect(oracle.cases.count == 17)
        for c in oracle.cases {
            let frames = try drawn(c)
            let approved = try c.frames()
            #expect(approved.count == c.frameCount)
            #expect(frames.map(\.milliseconds) == approved.map(\.ms), "\(c.id): delays")
            #expect(frames.count == approved.count, "\(c.id): frame count \(frames.count) vs \(approved.count)")
            for (index, (frame, expected)) in zip(frames, approved).enumerated() {
                let rows = WeatherOracle.hexRows(frame.canvas)
                if rows != expected.rows {
                    let firstBad = rows.indices.first { rows[$0] != expected.rows[$0] } ?? -1
                    Issue.record("\(c.id) frame \(index): first differing row \(firstBad)")
                    break
                }
            }
        }
    }

    /// Every recorded timeline is one GIF the TC002 plays on time: the
    /// measured ceilings, by the real encoder's bytes, and a scene
    /// `UlanziScene` accepts.
    @Test func everyTimelineFitsTheCeiling() throws {
        let oracle = try GitHubOracle.load()
        for c in oracle.cases {
            let frames = try drawn(c)
            #expect(frames.count <= WeatherFace.maxFrames, "\(c.id) frames")
            #expect(try gif(frames).base64EncodedString().count <= WeatherFace.maxBase64Bytes, "\(c.id) bytes")
            let scene = GitHubFace.scene(frames)
            #expect(throws: Never.self, "\(c.id)") { _ = try scene.jsonObject() }
        }
    }

    /// The rows ggen adds to wgen's `G` and `B`, drawn by the kit's faces.
    @Test func glyphTablesMatchTheOracle() throws {
        let oracle = try GitHubOracle.load()
        for (face, font) in [("small", PixelFont.proportional), ("big", PixelFont.big)] {
            let table = try #require(oracle.glyphs[face], "\(face) table")
            #expect(table.isEmpty == false)
            for (key, rows) in table.sorted(by: { $0.key < $1.key }) {
                let character = Character(key), width = rows[0].count
                #expect(font.covers(character), "\(face) \(key) is not in the face")
                #expect(font.columns(of: character) == width, "\(face) \(key) width")
                var canvas = PixelCanvas(width: width, height: rows.count)
                canvas.drawText(key, at: .zero, ink: .white, font: font)
                let drawnRows = (0..<rows.count).map { y in
                    String((0..<width).map { canvas[$0, y] == .white ? "#" : "." })
                }
                #expect(drawnRows == rows, "\(face) \(key)")
            }
        }
    }

    @Test func octiconTableMatchesTheOracle() throws {
        let oracle = try GitHubOracle.load()
        #expect(GitHubFace.octicons == oracle.octicons)
    }
}

@Suite struct GitHubFaceTests {
    private let config = GitHubTileConfig(repo: "artk0de/tea-rags", celebrationSeconds: 8)
    private let state = GitHubRepoState(nameWithOwner: "artk0de/tea-rags", stars: 1234, forks: 45, openPRs: 3)

    private func image(_ scene: UlanziScene) throws -> UlanziImage {
        #expect(scene.frames.count == 1)
        return try #require(scene.frames.first?.image.first)
    }

    @Test func theAmbientPageIsOnePanelSizedGifAtTheSignedOffDwell() throws {
        let delivery = GitHubFace.delivery(for: GitHubReading(content: .state(state), config: config))
        let frames = GitHubFace.timeline(
            ambient: state, noToken: false, config: config,
            dwellMilliseconds: GitHubFace.ambientDwellMilliseconds
        )
        #expect(GitHubFace.ambientDwellMilliseconds == 10_000)
        let shipped = try image(delivery.scene)
        #expect(shipped.position == (0, 0) && shipped.pixelSize == (52, 16))
        #expect(shipped.frameCount == frames.count && shipped.isAnimated)
        #expect(Data(base64Encoded: shipped.base64) == (try gif(frames)))
        #expect(delivery.interruptions.isEmpty)
    }

    @Test func noTokenAndNoDataDrawTheirOwnPages() throws {
        for (content, noToken) in [(GitHubReading.Content.noToken, true), (.noData, false)] {
            let delivery = GitHubFace.delivery(for: GitHubReading(content: content, config: config))
            let frames = GitHubFace.timeline(
                ambient: nil, noToken: noToken, config: config,
                dwellMilliseconds: GitHubFace.ambientDwellMilliseconds
            )
            #expect(Data(base64Encoded: try image(delivery.scene).base64) == (try gif(frames)), "\(content)")
        }
    }

    @Test func aReadWithStarsAndAForkCarriesTwoInterruptionsInOrder() throws {
        var events = GitHubEvents()
        events.newStars = ["Alice", "bob"]
        events.newStarCount = 2
        events.newForks = ["carol"]
        events.newForkCount = 1
        let delivery = GitHubFace.delivery(for: GitHubReading(content: .state(state), events: events, config: config))

        #expect(delivery.interruptions.map(\.scope) == [.everyPage, .ownPage])
        let stars = GitHubFace.celebration(
            kind: .star, count: 2, who: ["Alice", "bob"], prNumbers: [], celebrateMilliseconds: 8_000
        )
        let fork = GitHubFace.celebration(
            kind: .fork, count: 1, who: ["carol"], prNumbers: [], celebrateMilliseconds: 8_000
        )
        #expect(delivery.interruptions[0].scene == GitHubFace.scene(stars))
        #expect(delivery.interruptions[1].scene == GitHubFace.scene(fork))
        #expect(delivery.interruptions.map(\.duration) == [8, 8])
    }

    @Test func aNewPRInterruptsItsOwnPageNamingItsNumber() throws {
        var events = GitHubEvents()
        events.newPRs = [OpenPR(number: 42, author: "dave")]
        let delivery = GitHubFace.delivery(for: GitHubReading(content: .state(state), events: events, config: config))
        #expect(delivery.interruptions.map(\.scope) == [.ownPage])
        let pr = GitHubFace.celebration(
            kind: .pr, count: 1, who: ["dave"], prNumbers: [42], celebrateMilliseconds: 8_000
        )
        #expect(delivery.interruptions.first?.scene == GitHubFace.scene(pr))
    }

    /// The count is the burst's, not the logins the page could name.
    @Test func aStarBurstPastThePageShowsItsWholeCount() throws {
        var events = GitHubEvents()
        events.newStars = (1...10).map { "user\($0)" }
        events.newStarCount = 25
        let frames = GitHubFace.celebration(kind: .star, events: events, config: config)

        var hero = PixelCanvas(width: 34, height: 9)
        hero.drawText("+25", at: .zero, ink: GitHubFace.starInk, font: PixelFont.big)
        let settled = frames[5].canvas   // the first frame after the pop
        for y in 0..<9 {
            for x in 0..<34 {
                #expect(settled[18 + x, y] == hero[x, y], "(\(x), \(y))")
            }
        }
    }

    /// A marquee always finishes its pass, so the page is held for the
    /// timeline, not the setting, when the timeline is longer.
    @Test func aLongLoginHoldsTheClockUntilItsMarqueeEnds() throws {
        var events = GitHubEvents()
        events.newStars = ["a-really-long-github-login"]
        events.newStarCount = 1
        let delivery = GitHubFace.delivery(for: GitHubReading(content: .state(state), events: events, config: config))
        let frames = GitHubFace.celebration(kind: .star, events: events, config: config)
        let length = TimeInterval(frames.reduce(0) { $0 + $1.milliseconds }) / 1000
        #expect(length > 8)
        #expect(delivery.interruptions.map(\.duration) == [length])
    }

    @Test func theConnectorsStandardFaceIsThisOne() throws {
        let reading = GitHubReading(content: .state(state), config: config)
        #expect(GitHubFaces.standard.ulanzi(reading) == GitHubFace.delivery(for: reading))
    }
}
