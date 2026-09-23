import Foundation

/// Holds the connectors the app knows about, in registration order — which is
/// the order they are offered in.
public final class ConnectorRegistry: @unchecked Sendable {
    /// Builds the connector that runs one tile, from that tile's record.
    public typealias Factory = @Sendable (TileRecord) -> any Connector

    private var storage: [any Connector] = []
    /// Keyed by connector id. Beside `storage` and under the same lock, so a
    /// lookup never sees one half of a registration without the other.
    private var factories: [String: Factory] = [:]
    private let lock = NSLock()

    public init() {}

    /// Adds a connector, or replaces the one already registered under the same
    /// identifier. A replacement keeps the original's position.
    ///
    /// The search for an existing entry reads `id` off every connector already
    /// registered, and it does so holding a non-recursive lock. A conformer's
    /// `id` must therefore be a cheap, non-reentrant read — returning a stored
    /// property is the expected shape. An `id` getter that calls back into this
    /// registry deadlocks the caller.
    public func register(_ connector: any Connector) {
        lock.withLock {
            if let existing = storage.firstIndex(where: { $0.id == connector.id }) {
                storage[existing] = connector
            } else {
                storage.append(connector)
            }
        }
    }

    public var all: [any Connector] {
        lock.withLock { storage }
    }

    public func connector(id: String) -> (any Connector)? {
        all.first { $0.id == id }
    }

    /// Registers how a tile of this connector gets a connector of its own —
    /// what a connector watching one thing per tile needs, since one shared
    /// instance could only ever watch one. Replaces a factory already there.
    public func register(factory: @escaping Factory, for connectorId: String) {
        lock.withLock { factories[connectorId] = factory }
    }

    /// The connector that runs THIS tile: its factory's product, else the
    /// registered connector.
    ///
    /// The factory is called outside the lock: it builds a connector and may
    /// take its time doing so, and nothing it does needs the registry held.
    public func connector(for tile: TileRecord) -> (any Connector)? {
        let factory = lock.withLock { factories[tile.key.connectorId] }
        if let factory { return factory(tile) }
        return connector(id: tile.key.connectorId)
    }
}
