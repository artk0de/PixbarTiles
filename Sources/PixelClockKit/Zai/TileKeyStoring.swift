// Sources/PixelClockKit/Zai/TileKeyStoring.swift
import Foundation
import Security

/// Where a tile's API key lives: one secret per tile, out of the tile record.
///
/// A protocol rather than the keychain itself, so everything above it — the
/// paste field, the connector's reads, every test in the suite — runs against
/// a store it names, and no test ever reaches the user's login keychain.
///
/// Nothing here caches. A look is always a real look, for the same reason the
/// Claude reader's was: a key pasted into the tile's detail must be on its way
/// to the service at the next poll, not at the next launch.
public protocol TileKeyStoring: Sendable {
    /// The key stored under this account, or nil when there is none. A failed
    /// read reads as no key: the item is ours, so a failure means it is not
    /// there, and there is nothing honest to say beyond that.
    func key(for account: String) -> String?
    /// Stores a key under this account, replacing any key already there.
    /// Throws when the store refuses — a paste the store did not take is a
    /// paste the user has to be told about, not one that silently never was.
    func save(_ key: String, for account: String) throws
    /// Takes a key away. Removing one that is not there is fine: the wanted
    /// end state is "no key", and that is what exists after.
    func removeKey(for account: String) throws
}

/// The login keychain, under this app's own service name.
///
/// These items are the app's own — written by `save`, read by `key` — so,
/// unlike the Claude credential this app used to read, looking at them raises
/// no prompt about another program's secrets.
public struct LoginKeychainStore: TileKeyStoring {
    /// The service every one of this app's items is filed under. Namespaced to
    /// the app because the login keychain is shared with every other program's
    /// items: an unadorned account name would be a collision waiting for a
    /// stranger to write the same string.
    public static let service = "PixelClockTiles tile keys"

    public init() {}

    public func key(for account: String) -> String? {
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(
                Self.query(service: Self.service, account: account, returningData: true)
                    as CFDictionary, &item
            ) == errSecSuccess,
            let blob = item as? Data
        else { return nil }
        return String(data: blob, encoding: .utf8)
    }

    public func save(_ key: String, for account: String) throws {
        let status = SecItemAdd(
            Self.writeQuery(service: Self.service, account: account, data: Data(key.utf8))
                as CFDictionary,
            nil
        )
        // Already there is not a failure — it means the paste replaces an
        // earlier key, which is the ordinary case, and the update is what
        // makes it true.
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let status = SecItemUpdate(
                Self.query(service: Self.service, account: account, returningData: false)
                    as CFDictionary,
                [kSecValueData as String: Data(key.utf8)] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw TileKeyError(status: status)
            }
            return
        }
        throw TileKeyError(status: status)
    }

    public func removeKey(for account: String) throws {
        let status = SecItemDelete(
            Self.deleteQuery(service: Self.service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TileKeyError(status: status)
        }
    }

    // MARK: - The queries, written down where tests can pin them

    /// A lookup: our class, our service, this item — and the data back, when
    /// the caller wants what is stored rather than proof it is there.
    static func query(
        service: String, account: String, returningData: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    /// A write: the whole item, secret included.
    static func writeQuery(service: String, account: String, data: Data) -> [String: Any] {
        var query = Self.query(service: service, account: account, returningData: false)
        query[kSecValueData as String] = data
        return query
    }

    /// A removal: enough to name the item, nothing more.
    static func deleteQuery(service: String, account: String) -> [String: Any] {
        Self.query(service: service, account: account, returningData: false)
    }
}

/// Why the store refused. `status` is the OS Security code, for whoever reads
/// the console — there is nothing more specific a generic-password item can
/// honestly be said to have failed at.
public struct TileKeyError: Error, Sendable, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// A keychain in memory, for the suite.
///
/// The fixture every test may stand on instead of the user's login keychain,
/// which no test may ever touch. It answers to exactly the contract above —
/// same round-trip, same replace, same silent success on removing what is not
/// there — because it is also the shape any future store has to match.
///
/// A class so the state it holds is the state everyone holding it sees: a
/// store that forked on assignment would hand back a key nobody saved. The
/// lock is what makes the unchecked `Sendable` a true sentence — every touch
/// of the items goes through it.
public final class MemoryKeychainStore: TileKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    public func key(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    public func save(_ key: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = key
    }

    public func removeKey(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: account)
    }
}
