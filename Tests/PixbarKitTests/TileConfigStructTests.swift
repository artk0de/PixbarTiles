import Foundation
import Testing
@testable import PixbarKit

/// A tile config as a kind id and that kind's parameters.
@Suite struct TileConfigStructTests {
    private let place = Coordinates(latitude: 55.75, longitude: 37.62)

    private func roundTrip(_ config: TileConfig) throws -> TileConfig {
        try JSONDecoder().decode(TileConfig.self, from: JSONEncoder().encode(config))
    }

    @Test func aConfigNamesItsKindAndOpensToItsParameters() {
        let config = TileConfig(GitHubTileConfig(repo: "owner/name"), kind: GitHubKind.self)
        #expect(config.kindId == GitHubKind.id)
        #expect(config.value(as: GitHubTileConfig.self)?.repo == "owner/name")
        #expect(config.value(as: WeatherTileConfig.self) == nil)
        #expect(config == .github(GitHubTileConfig(repo: "owner/name")))
    }

    @Test func everyKindsConfigSurvivesARoundTrip() throws {
        let samples: [TileConfig] = [
            .weather(place),
            .claude(ClaudeTileConfig()),
            .zai(ZaiTileConfig(keyAccount: "k")),
            .github(GitHubTileConfig(repo: "owner/name")),
            TileConfig(NoParameters(), kind: AnecdotesKind.self),
            .vpn(VPNTileConfig(vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .off)),
            TileConfig(NightLightTileConfig(scene: .glow), kind: NightLightKind.self),
        ]
        #expect(Set(samples.map(\.kindId)) == Set(TileKinds.all.map { $0.id }))
        for sample in samples {
            #expect(try roundTrip(sample) == sample, "kind \(sample.kindId)")
        }
    }

    @Test func aConfigNamingNoKnownKindIsRefused() {
        for text in [#"{}"#, #"{"nope":{}}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(TileConfig.self, from: Data(text.utf8))
            }
        }
    }

    @Test func configsOfDifferentKindsAreNeverEqual() {
        #expect(TileConfig.weather(place) != .github(GitHubTileConfig(repo: "a/b")))
        #expect(TileConfig.weather(place) != .weather(Coordinates(latitude: 0, longitude: 0)))
    }
}
