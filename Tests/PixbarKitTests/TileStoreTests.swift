import Foundation
import Testing
@testable import PixbarKit

private let desk = UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11")!
private let kitchen = UUID(uuidString: "0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D")!

private func tile(
    on clock: UUID = desk, _ connector: String, paused: Bool = false, every seconds: Int = 600
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: seconds)
    )
}

// Written out rather than encoded by the code under test, for the reason the
// clocks' shape test gives. Phase 4 extends `policy` with keys of its own and
// has to decode exactly this.
@Test func tilesAreReadFromTheShapeTheyAreStoredIn() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
        Data(
            #"""
            [{"key":{"clockId":"6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11","connectorId":"weather",\#
            "instance":""},"policy":{"isPaused":true,"refreshSeconds":600},\#
            "lastDeliveredAt":777000000},\#
            {"key":{"clockId":"6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11","connectorId":"claude",\#
            "instance":""},"policy":{"isPaused":false,"refreshSeconds":300}}]
            """#.utf8
        ),
        forKey: "tiles"
    )

    #expect(
        TileStore(defaults: defaults).all() == [
            TileRecord(
                key: TileKey(clockId: desk, connectorId: "weather"),
                policy: TilePolicyRecord(isPaused: true, refreshSeconds: 600),
                lastDeliveredAt: Date(timeIntervalSinceReferenceDate: 777_000_000)
            ),
            TileRecord(
                key: TileKey(clockId: desk, connectorId: "claude"),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 300)
            ),
        ]
    )
}

@Test func aKeyThatDoesNotDecodeReadsAsNoTiles() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not tiles".utf8), forKey: TileStore.key)

    #expect(TileStore(defaults: defaults).all().isEmpty)
}

@Test func replacedTilesSurviveARelaunchInOrder() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = [tile("anecdotes", every: 1800), tile("weather"), tile("claude", every: 300)]

    try TileStore(defaults: defaults).replaceAll(tiles)

    #expect(TileStore(defaults: defaults).all() == tiles)
}

// The key is the clock AND the connector. The same connector on two clocks is
// two tiles, and a change to one is not a change to the other.
@Test func anUpdateChangesOnlyTheTileWithThatKey() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TileStore(defaults: defaults)
    let onDesk = tile(on: desk, "weather")
    let inKitchen = tile(on: kitchen, "weather")
    try store.replaceAll([onDesk, inKitchen])

    store.update(inKitchen) { $0.policy.isPaused = true }

    #expect(store.all().first == onDesk)
    #expect(store.all().last?.policy.isPaused == true)
}

// Applied to what is stored, not to the template: a caller that only knows
// some of a tile's fields must not write its guesses over the others.
@Test func anUpdateLandsOnTheStoredTileRatherThanOnTheTemplate() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TileStore(defaults: defaults)
    try store.replaceAll([tile("weather", every: 700)])
    let delivered = Date(timeIntervalSinceReferenceDate: 777_000_000)

    store.update(tile("weather", every: 300)) { $0.lastDeliveredAt = delivered }

    #expect(store.all().first?.policy.refreshSeconds == 700)
    #expect(store.all().first?.lastDeliveredAt == delivered)
}

@Test func anUpdateStoresATileThatWasNotStoredYet() throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TileStore(defaults: defaults)

    store.update(tile("claude", every: 300)) { $0.policy.isPaused = true }

    #expect(store.all() == [tile("claude", paused: true, every: 300)])
}

@Test func concurrentUpdatesThroughTwoTileStoresAreNeverLost() async throws {
    let suite = "tile-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = TileStore(defaults: defaults)
    let second = TileStore(defaults: defaults)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            let store = index.isMultiple(of: 2) ? first : second
            let added = tile("connector-\(index)")
            group.addTask { store.update(added) { _ in } }
        }
    }

    #expect(first.all().count == 16)
}
