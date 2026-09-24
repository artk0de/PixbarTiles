// Sources/PixbarKit/Secrets/SecretStoring.swift
import Foundation
import Security

/// Whose secret it is: one tile's own key, or one connector's, shared by
/// every tile of that connector — a GitHub token reads every repository the
/// user watches, so asking for it once per tile would be asking three times
/// for the same string.
public enum SecretAccount: Hashable, Sendable, Codable {
    case tile(TileKey)
    case connector(String)

    /// The stable string the account is filed under — the key in the
    /// encrypted file's map. A prefix per case, so a connector named like a
    /// tile's key can never read that tile's secret.
    public var storageKey: String {
        switch self {
        case .tile(let key):
            "tile:\(key.clockId.uuidString).\(key.connectorId).\(key.instance)"
        case .connector(let id):
            "connector:\(id)"
        }
    }
}

/// Where the app's secrets live: out of the tile records, behind a port.
///
/// A protocol so the paste field, the connectors' reads and every test run
/// against a store they name, and no test ever reaches the user's real file.
/// Nothing here caches, for the same reason the keychain store did not: a key
/// pasted now must be on its way to the service at the next poll.
public protocol SecretStoring: Sendable {
    /// The secret stored under this account, or nil when there is none. A
    /// failed read reads as no secret — there is nothing honest to say beyond
    /// "it is not there".
    func secret(for account: SecretAccount) -> String?
    /// Stores a secret under this account, replacing any already there.
    /// Throws when the store refuses: a paste the store did not take is one
    /// the user has to be told about.
    func save(_ secret: String, for account: SecretAccount) throws
    /// Takes a secret away. Removing one that is not there is fine: the
    /// wanted end state is "no secret", and that is what exists after.
    func remove(for account: SecretAccount) throws
}

/// Why a secret store refused, in words for whoever reads the console.
public struct SecretStoreError: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// A secret store in memory, for the suite.
///
/// A class so the state it holds is the state everyone holding it sees; the
/// lock is what makes the unchecked `Sendable` a true sentence.
public final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecretAccount: String] = [:]

    public init() {}

    public func secret(for account: SecretAccount) -> String? {
        lock.withLock { items[account] }
    }

    public func save(_ secret: String, for account: SecretAccount) throws {
        lock.withLock { items[account] = secret }
    }

    public func remove(for account: SecretAccount) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

/// The login keychain, under this app's own service name.
///
/// These items are the app's own — written by `save`, read by `key` — so,
/// unlike the Claude credential this app used to read, looking at them raises
/// no prompt about another program's secrets.
///
/// Legacy: z.ai keys lived here until the encrypted file replaced it, because
/// an ad-hoc-signed app is asked for the password after every re-sign. Kept
/// only so the app's one-time migration can read the old items and delete
/// them; nothing new is written here.
public struct LoginKeychainStore: Sendable {
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
