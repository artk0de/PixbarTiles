import Foundation
import Testing
@testable import PixelClockKit

// A single tile's name is its connector's id, so every page already on a clock
// keeps the name it was delivered under before tiles could be instanced.
@Test func aSingleTileKeepsItsConnectorIdAsItsName() {
    #expect(TileKey(clockId: UUID(), connectorId: "weather").tileId == "weather")
}

@Test func anInstancedTileIsNamedByConnectorAndInstance() {
    #expect(
        TileKey(clockId: UUID(), connectorId: "github", instance: "artk0de/tea-rags").tileId
            == "github.artk0de/tea-rags"
    )
}
