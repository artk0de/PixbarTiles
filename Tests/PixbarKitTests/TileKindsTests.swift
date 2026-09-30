import Foundation
import Testing
@testable import PixbarKit

/// Every tile's catalogue facts, one kind per tile and listed once.
@Suite struct TileKindsTests {
    private struct Facts: Equatable {
        let presentation: TilePresentation
        let models: Set<ClockModel>
        let instancing: Instancing
        let isAudible: Bool
    }

    /// What the catalogue answered for each shipped tile before the kinds
    /// existed, written out so a kind cannot drift from it unseen.
    private let shipped: [String: Facts] = [
        "weather": Facts(
            presentation: TilePresentation(category: .weather, icon: "cloud.sun", blurb: "The sky where the clock is"),
            models: [.awtrix3, .ulanziTC002], instancing: .single, isAudible: false
        ),
        "claude": Facts(
            presentation: TilePresentation(category: .dev, icon: "terminal", blurb: "Claude usage, from the status line"),
            models: [.awtrix3, .ulanziTC002], instancing: .single, isAudible: false
        ),
        "zai": Facts(
            presentation: TilePresentation(category: .dev, icon: "chart.bar", blurb: "z.ai usage, week to date"),
            models: [.awtrix3, .ulanziTC002], instancing: .single, isAudible: false
        ),
        "github": Facts(
            presentation: TilePresentation(category: .dev, icon: "star", blurb: "A repository's stars, forks and PRs"),
            models: [.awtrix3, .ulanziTC002], instancing: .perKey, isAudible: false
        ),
        "anecdotes": Facts(
            presentation: TilePresentation(category: .system, icon: "text.bubble", blurb: "The day's anecdotes, spoken"),
            models: [.awtrix3], instancing: .single, isAudible: true
        ),
        "vpn": Facts(
            presentation: TilePresentation(category: .network, icon: "lock.shield", blurb: "A watched VPN, as a lamp on the clock"),
            models: [.awtrix3], instancing: .perKey, isAudible: false
        ),
    ]

    @Test func everyKindHasItsOwnId() {
        let ids = TileKinds.all.map { $0.id }
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(shipped.keys))
    }

    @Test func aKindIsFoundByItsIdAndNothingElseIs() {
        for kind in TileKinds.all {
            #expect(TileKinds.kind(id: kind.id).map { $0.id } == kind.id)
        }
        #expect(TileKinds.kind(id: "nope") == nil)
    }

    @Test func eachKindAnswersWhatTheCatalogueAnswered() {
        for kind in TileKinds.all {
            let facts = Facts(
                presentation: kind.presentation, models: kind.models,
                instancing: kind.instancing, isAudible: kind.isAudible
            )
            #expect(facts == shipped[kind.id], "kind \(kind.id)")
        }
    }
}
