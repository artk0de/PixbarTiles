import Foundation
import Testing
@testable import PixbarKit

@Test func theCatalogueCarriesPritunlAndAmneziaUnderStableIds() {
    #expect(WatchedVPN.catalogue.map(\.id) == ["pritunl", "amnezia"])
    #expect(WatchedVPN.catalogue.map(\.displayName) == ["Pritunl", "Amnezia"])
    #expect(WatchedVPN.preset(id: "amnezia") == .amnezia)
    #expect(WatchedVPN.preset(id: "wireguard") == nil)
}

@Test func theLampsAreCalledWhereTheyAre() {
    #expect(IndicatorSlot.allCases.map(\.lampName) == ["top", "middle", "bottom"])
}
