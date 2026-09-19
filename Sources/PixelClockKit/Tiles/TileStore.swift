import Foundation

/// The tiles of every clock, as one JSON array under one `UserDefaults` key.
public final class TileStore: @unchecked Sendable {
    public static let key = "tiles"

    /// Static, for the reason `ClockStore`'s is.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// In stored order. A key that does not decode reads as no tiles.
    public func all() -> [TileRecord] {
        Self.lock.withLock { stored() }
    }

    /// Replaces every tile. Throws for the reason `ClockStore.replaceAll`
    /// does.
    public func replaceAll(_ tiles: [TileRecord]) throws {
        let data = try JSONEncoder().encode(tiles)
        Self.lock.withLock { defaults.set(data, forKey: Self.key) }
    }

    /// Applies `change` to the stored tile with `tile`'s key, or stores
    /// `tile` with the change applied when there is none. The change lands on
    /// what is stored, so fields the caller does not know about survive it.
    public func update(_ tile: TileRecord, _ change: (inout TileRecord) -> Void) {
        Self.lock.withLock {
            var tiles = stored()
            if let index = tiles.firstIndex(where: { $0.key == tile.key }) {
                change(&tiles[index])
            } else {
                var inserted = tile
                change(&inserted)
                tiles.append(inserted)
            }
            guard let data = try? JSONEncoder().encode(tiles) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    private func stored() -> [TileRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([TileRecord].self, from: data)) ?? []
    }
}
