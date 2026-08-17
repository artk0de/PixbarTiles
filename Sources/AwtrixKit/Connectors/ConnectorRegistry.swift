import Foundation

/// Holds the connectors the app knows about, in registration order — which is
/// the order they are offered in.
public final class ConnectorRegistry: @unchecked Sendable {
    private var storage: [any Connector] = []
    private let lock = NSLock()

    public init() {}

    /// Adds a connector, or replaces the one already registered under the same
    /// identifier. A replacement keeps the original's position.
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
}
