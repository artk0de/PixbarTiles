import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// A tile card's title names an instanced tile's instance — `GitHub -
// TeaRAGs` — upright, in the card's pixel face. (An italic, parenthesised
// form was tried and was unreadable live.)

@MainActor
@Suite struct TileCardTitleTests {
    private let face = PixelFont.standard

    /// The title map: the name and the secondary name upright, joined by a
    /// spaced hyphen — the italic parenthesised form was unreadable live.
    @Test func theTitleIsTheNameAHyphenAndTheSecondaryName() {
        let map = PanelGlyph.title("GitHub", secondary: "TeaRAGs", in: face, lit: "G")
        #expect(map == PanelGlyph.text("GitHub - TeaRAGs", in: face, lit: "G"))
        #expect(PanelGlyph.title("Weather", secondary: nil, in: face, lit: "G")
            == PanelGlyph.text("Weather", in: face, lit: "G"))
    }

    @Test func theTitleSaysItInWordsToo() {
        #expect(TileTitle(name: "GitHub", secondary: "TeaRAGs").text == "GitHub - TeaRAGs")
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
    /// `running…`, `held` — in upright pixels; a trouble keeps its sentence
    /// line.
    @Test func theOutcomeLineIsTheResultWhenNothingIsWrong() {
        #expect(TileCardOutcome.of(trouble: nil, held: false, result: "delivered") == "delivered")
        #expect(TileCardOutcome.of(trouble: nil, held: true, result: "delivered") == "held")
        #expect(TileCardOutcome.of(trouble: nil, held: false, result: nil) == nil)
        let trouble = TileCardTrouble.of(failure: "x", diagnosis: nil)
        #expect(TileCardOutcome.of(trouble: trouble, held: false, result: "delivered") == nil)
    }
}
