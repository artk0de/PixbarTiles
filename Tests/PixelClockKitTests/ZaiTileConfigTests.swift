// Tests/PixelClockKitTests/ZaiTileConfigTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The handle, never the key. A z.ai tile's config names WHERE its key lives —
// the keychain account — and carries no secret: the tiles JSON in UserDefaults
// must never hold the key, so the paste field stores it in the store under the
// account this derivation names.

@Suite struct ZaiTileConfigTests {
    private let clockId = UUID(uuidString: "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F")!

    /// A `.single` connector sits on a clock once, so clock plus connector is
    /// the whole tile: the handle is derived from the tile key and nothing
    /// else. Deriving beats asking — a tile created before its config was
    /// saved still has the same address its key will live under.
    @Test func theAccountIsDerivedFromTheTileKey() {
        let key = TileKey(clockId: clockId, connectorId: "zai")

        #expect(ZaiTileConfig.account(for: key) == "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F.zai")
    }

    /// Two clocks' z.ai tiles must never share an account: the key is per
    /// tile, and the clocks are different tiles.
    @Test func anotherClockDerivesAnotherAccount() {
        let other = TileKey(clockId: UUID(), connectorId: "zai")

        #expect(ZaiTileConfig.account(for: other) != ZaiTileConfig.account(
            for: TileKey(clockId: clockId, connectorId: "zai")
        ))
    }
}
