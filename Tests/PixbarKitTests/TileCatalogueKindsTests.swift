import Foundation
import Testing
@testable import PixbarKit

/// The catalogue's answers are the kinds' answers.
@Suite struct TileCatalogueKindsTests {
    private let clockId = UUID()

    @Test func everyKindPresentsAsItSays() {
        for kind in TileKinds.all {
            #expect(TilePresentation.of(connectorId: kind.id) == kind.presentation, "kind \(kind.id)")
        }
        #expect(TilePresentation.of(connectorId: "nope") == TilePresentation(category: .dev, icon: "app.dashed", blurb: ""))
    }

    @Test func anInstanceIsNamedByItsKind() {
        let repo = TileRecord(
            key: TileKey(clockId: clockId, connectorId: GitHubKind.id, instance: "owner/tearags"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
            config: .github(GitHubTileConfig(repo: "Owner/TeaRAGs"))
        )
        let named = TileRecord(
            key: repo.key, policy: repo.policy,
            config: .github(GitHubTileConfig(repo: "Owner/TeaRAGs", shortName: " Tea "))
        )
        let weather = TileRecord(
            key: TileKey(clockId: clockId, connectorId: WeatherKind.id),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60)
        )
        #expect(TilePresentation.secondaryName(of: repo) == "TeaRAGs")
        #expect(TilePresentation.secondaryName(of: named) == "Tea")
        #expect(TilePresentation.secondaryName(of: weather) == nil)
    }

    @Test func aCandidateOfAKnownKindCarriesTheKindsFacts() {
        let candidate = TileCandidate(VPNConnector(isUp: { _ in false }))
        #expect(candidate.connectorId == VPNKind.id)
        #expect(candidate.models == VPNKind.models)
        #expect(candidate.instancing == VPNKind.instancing)
        #expect(candidate.storeIcon == VPNKind.presentation.icon)
        #expect(candidate.blurb == VPNKind.presentation.blurb)
    }
}
