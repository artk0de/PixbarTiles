import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// The keychain prompts for its password after every re-sign, so z.ai keys
// move to the encrypted file once: read from the keychain, written under the
// tile's own account, deleted from the keychain only once the file holds them.
// No test here touches the login keychain — a stub stands in and counts.

/// A keychain that answers from a dictionary and writes down every call.
private final class StubKeychain: LegacyKeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private(set) var reads: [String] = []
    private(set) var removals: [String] = []

    init(_ items: [String: String] = [:]) {
        self.items = items
    }

    var calls: Int { lock.withLock { reads.count + removals.count } }

    func key(for account: String) -> String? {
        lock.withLock {
            reads.append(account)
            return items[account]
        }
    }

    func removeKey(for account: String) throws {
        lock.withLock {
            removals.append(account)
            items.removeValue(forKey: account)
        }
    }
}

/// Refuses every save, the way a file store with no hardware identity does.
private final class RefusingSecretStore: SecretStoring, @unchecked Sendable {
    func secret(for account: SecretAccount) -> String? { nil }
    func save(_ secret: String, for account: SecretAccount) throws {
        throw SecretStoreError(reason: "refused")
    }
    func remove(for account: SecretAccount) throws {}
}

/// A z.ai tile on this clock, its handle derived the way the app derives it.
@discardableResult
private func storeAZaiTile(on clock: ClockRecord, in defaults: UserDefaults) throws -> TileKey {
    let key = TileKey(clockId: clock.id, connectorId: ZaiUsageConnector.connectorId)
    try TileStore(defaults: defaults).replaceAll([
        TileRecord(
            key: key,
            policy: TilePolicyRecord(TileDefaults.codeUsage),
            config: .zai(ZaiTileConfig(keyAccount: ZaiTileConfig.account(for: key)))
        ),
    ])
    return key
}

@Suite struct SecretsMigrationTests {
    @Test func movesEveryZaiKeyAndDeletesTheKeychainItem() throws {
        try withFreshDefaults { defaults in
            let clock = try storeAClock(in: defaults)
            let key = try storeAZaiTile(on: clock, in: defaults)
            let account = ZaiTileConfig.account(for: key)
            let keychain = StubKeychain([account: "k"])
            let secrets = MemorySecretStore()

            SecretsMigration(defaults: defaults, keychain: keychain, secrets: secrets).run()

            #expect(secrets.secret(for: .tile(key)) == "k")
            #expect(keychain.removals == [account])
            #expect(defaults.bool(forKey: SecretsMigration.markerKey))
        }
    }

    /// The tile then reads "no key", the state it would be in after any other
    /// loss — and the item stays where it was, so nothing is destroyed.
    @Test func aRefusedReadLeavesTheItemAndStillSetsTheMarker() throws {
        try withFreshDefaults { defaults in
            let clock = try storeAClock(in: defaults)
            let key = try storeAZaiTile(on: clock, in: defaults)
            let keychain = StubKeychain()
            let secrets = MemorySecretStore()

            SecretsMigration(defaults: defaults, keychain: keychain, secrets: secrets).run()

            #expect(secrets.secret(for: .tile(key)) == nil)
            #expect(keychain.removals.isEmpty)
            #expect(defaults.bool(forKey: SecretsMigration.markerKey))
        }
    }

    /// The keychain item goes only once the file holds its copy: a save the
    /// store refused must not cost the user the key.
    @Test func aRefusedSaveKeepsTheKeychainItem() throws {
        try withFreshDefaults { defaults in
            let clock = try storeAClock(in: defaults)
            let key = try storeAZaiTile(on: clock, in: defaults)
            let keychain = StubKeychain([ZaiTileConfig.account(for: key): "k"])

            SecretsMigration(
                defaults: defaults, keychain: keychain, secrets: RefusingSecretStore()
            ).run()

            #expect(keychain.removals.isEmpty)
        }
    }

    /// Every keychain read is a possible password prompt, so a second launch
    /// asks it nothing.
    @Test func runsOnce() throws {
        try withFreshDefaults { defaults in
            let clock = try storeAClock(in: defaults)
            let key = try storeAZaiTile(on: clock, in: defaults)
            let secrets = MemorySecretStore()
            SecretsMigration(
                defaults: defaults,
                keychain: StubKeychain([ZaiTileConfig.account(for: key): "k"]),
                secrets: secrets
            ).run()
            let again = StubKeychain([ZaiTileConfig.account(for: key): "k"])

            SecretsMigration(defaults: defaults, keychain: again, secrets: secrets).run()

            #expect(again.calls == 0)
        }
    }

    @Test func aTileWithoutAKeyIsSkipped() throws {
        try withFreshDefaults { defaults in
            let clock = try storeAClock(in: defaults)
            try storeTheMigratedTiles(on: clock, in: defaults)
            let keychain = StubKeychain()

            SecretsMigration(
                defaults: defaults, keychain: keychain, secrets: MemorySecretStore()
            ).run()

            #expect(keychain.calls == 0)
            #expect(defaults.bool(forKey: SecretsMigration.markerKey))
        }
    }

    @Test func theSecretsMigrationWritesItsMarkerLast() throws {
        try withFreshDefaults { defaults in
            let clock = try storeAClock(in: defaults)
            let key = try storeAZaiTile(on: clock, in: defaults)

            SecretsMigration(
                defaults: defaults,
                keychain: StubKeychain([ZaiTileConfig.account(for: key): "k"]),
                secrets: MemorySecretStore()
            ).run()

            #expect(defaults.writes.last == SecretsMigration.markerKey)
        }
    }
}
