import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// A tile card's title names an instanced tile's instance — `GitHub
// (TeaRAGs)` — with the parenthesised part in italic pixels: the same face,
// each row sheared right by one column per two rows from the bottom.

@MainActor
@Suite struct TileCardTitleTests {
    private let face = PixelFont.standard

    /// Italic is the upright word with each row shifted: the bottom two rows
    /// not at all, the top row the most — and every row the same width.
    @Test func italicShearsTheUprightRows() {
        let upright = PanelGlyph.text("(Ab)", in: face, lit: "G")
        let italic = PanelGlyph.text("(Ab)", in: face, lit: "G", italic: true)
        #expect(face.height == 7)
        let shifts = [3, 2, 2, 1, 1, 0, 0]
        #expect(italic.count == upright.count)
        for (row, shift) in shifts.enumerated() {
            let expected = String(repeating: ".", count: shift) + upright[row]
                + String(repeating: ".", count: 3 - shift)
            #expect(italic[row] == expected, "row \(row)")
        }
        #expect(PanelGlyph.text("(Ab)", in: face, lit: "G", italic: false) == upright)
    }

    /// The title map: the name upright, a space, the secondary name in
    /// parentheses and italic.
    @Test func theTitleIsTheNameThenTheItalicSecondaryName() {
        let map = PanelGlyph.title("GitHub", secondary: "TeaRAGs", in: face, lit: "G")
        let name = PanelGlyph.text("GitHub ", in: face, lit: "G")
        let tail = PanelGlyph.text("(TeaRAGs)", in: face, lit: "G", italic: true)
        let gap = String(repeating: ".", count: face.gap)
        #expect(map == zip(name, tail).map { $0 + gap + $1 })
        #expect(PanelGlyph.title("Weather", secondary: nil, in: face, lit: "G")
            == PanelGlyph.text("Weather", in: face, lit: "G"))
    }

    @Test func theTitleSaysItInWordsToo() {
        #expect(TileTitle(name: "GitHub", secondary: "TeaRAGs").text == "GitHub (TeaRAGs)")
        #expect(TileTitle(name: "Weather", secondary: nil).text == "Weather")
    }

    /// The model asks the kit for the secondary name; the tile's own name is
    /// the connector's.
    @Test func theModelTitlesAGitHubTileByItsShortNameOrRepo() async {
        let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.5")
        let github = ConnectorFactories.namingInstances(transport: StubTransport())
            .first { $0.id == GitHubConnector.connectorId }!
        func tile(_ config: GitHubTileConfig) -> TileRecord {
            TileRecord(
                key: TileKey(clockId: desk.id, connectorId: GitHubConnector.connectorId, instance: config.repo.lowercased()),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
                config: .github(config)
            )
        }
        let named = tile(GitHubTileConfig(repo: "artk0de/TeaRAGs-MCP", shortName: "TeaRAGs"))
        let plain = tile(GitHubTileConfig(repo: "a/Other"))
        let model = testModel(connectors: [github], clocks: [desk], tiles: [named, plain])

        #expect(model.tileTitle(of: named) == TileTitle(name: "GitHub", secondary: "TeaRAGs"))
        #expect(model.tileTitle(of: plain) == TileTitle(name: "GitHub", secondary: "Other"))
        await model.teardown()
    }

    /// The card's bottom-left line: the ordinary outcome — `delivered`,
    /// `running…`, `held` — in italic pixels; a trouble keeps its sentence
    /// line.
    @Test func theOutcomeLineIsTheResultWhenNothingIsWrong() {
        #expect(TileCardOutcome.of(trouble: nil, held: false, result: "delivered") == "delivered")
        #expect(TileCardOutcome.of(trouble: nil, held: true, result: "delivered") == "held")
        #expect(TileCardOutcome.of(trouble: nil, held: false, result: nil) == nil)
        let trouble = TileCardTrouble.of(failure: "x", diagnosis: nil)
        #expect(TileCardOutcome.of(trouble: trouble, held: false, result: "delivered") == nil)
    }
}
