import Foundation
import Testing
@testable import PixelClockKit

// A single tile's name is its connector's id, so every page already on a clock
// keeps the name it was delivered under before tiles could be instanced.
@Test func aSingleTileKeepsItsConnectorIdAsItsName() {
    #expect(TileKey(clockId: UUID(), connectorId: "weather").tileId == "weather")
}

// Pinned: slug "artk0de-tea-rags" plus the low 24 bits of FNV-1a-32 over the
// instance's UTF-8 bytes, 0xa33a6d — cross-checked with an independent Python
// computation, so a change to the hash renames every GitHub page on a clock.
@Test func anInstancedTileIsNamedByConnectorAndInstance() {
    #expect(
        TileKey(clockId: UUID(), connectorId: "github", instance: "artk0de/tea-rags").tileId
            == "github-artk0de-tea-rags-a33a6d"
    )
}

// Both clocks interpolate the name into `/api/custom?name=` unencoded, and a
// repository key carries '/' and '.'.
@Test func anInstancedTileIdUsesOnlyWireSafeCharacters() {
    let long = String(repeating: "Ab.c/", count: 20)
    for instance in ["artk0de/tea-rags", "Foo.Bar/baz_qux", long] {
        let tileId = TileKey(clockId: UUID(), connectorId: "github", instance: instance).tileId
        #expect(tileId.wholeMatch(of: /[a-z0-9-]+/) != nil, "\(tileId)")
        #expect(!tileId.contains("--"), "\(tileId)")
    }
}

@Test func instancesThatSlugAlikeStillDiffer() {
    let clock = UUID()
    let dotted = TileKey(clockId: clock, connectorId: "github", instance: "a.b").tileId
    let dashed = TileKey(clockId: clock, connectorId: "github", instance: "a-b").tileId
    #expect(dotted != dashed)
}
