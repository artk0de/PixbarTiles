// Tests/PixelClockTilesAppTests/ZaiTileWiringTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The paste is the key's whole life above the store: typed into the tile's
// detail, written to the secret store under the tile's own account, remembered
// by the record as a HANDLE only. The tiles JSON in UserDefaults must never
// hold the secret, so every test here reads the stored records back and looks.

/// Refuses every write, the way a store with no hardware identity does.
private final class LockedSecretStore: SecretStoring, @unchecked Sendable {
    func secret(for account: SecretAccount) -> String? { nil }
    func save(_ secret: String, for account: SecretAccount) throws {
        throw SecretStoreError(reason: "locked")
    }
    func remove(for account: SecretAccount) throws {
        throw SecretStoreError(reason: "locked")
    }
}

@MainActor
@Suite struct ZaiTileWiringTests {
    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    private var key: TileKey { TileKey(clockId: clock.id, connectorId: ZaiUsageConnector.connectorId) }
    private var zaiTile: [TileRecord] {
        [TileRecord(key: key, policy: TilePolicyRecord(TileDefaults.codeUsage))]
    }

    private func makeModel(
        _ secrets: any SecretStoring = MemorySecretStore()
    ) -> (model: AppModel, defaults: UserDefaults) {
        let defaults = UserDefaults(suiteName: "zai-wiring-\(UUID().uuidString)")!
        let model = testModel(
            defaults: defaults, clocks: [clock], tiles: zaiTile, secrets: secrets
        )
        return (model, defaults)
    }

    /// The records as the tiles store holds them — read back the way any
    /// other reader of the defaults would, not through the model's own copy.
    private func storedRecords(_ defaults: UserDefaults) -> [TileRecord] {
        TileStore(defaults: defaults).all()
    }

    @Test func aPasteLandsInTheStoreUnderTheTilesOwnAccount() {
        let secrets = MemorySecretStore()
        let (model, _) = makeModel(secrets)

        model.saveZaiKey("sk-paste", for: key)

        #expect(secrets.secret(for: .tile(key)) == "sk-paste")
        #expect(model.hasZaiKey(for: key))
    }

    /// The record remembers the handle and nothing else: encode what the
    /// tiles store holds and look for the key. It is not there — the tiles
    /// JSON in UserDefaults must never carry the secret.
    @Test func theStoredRecordCarriesTheHandleAndNeverTheKey() throws {
        let (model, defaults) = makeModel()
        model.saveZaiKey("sk-paste", for: key)

        let record = try #require(
            storedRecords(defaults).first { $0.key == key }
        )
        #expect(record.config?.key?.keyAccount == ZaiTileConfig.account(for: key))
        let stored = String(
            decoding: try JSONEncoder().encode(storedRecords(defaults)), as: UTF8.self
        )
        #expect(stored.contains("sk-paste") == false)
    }

    /// A blank paste is a removal, not a save of nothing: the field is how a
    /// key is taken back, and clearing it leaves the tile keyless.
    @Test func aBlankPasteTakesTheKeyAway() {
        let secrets = MemorySecretStore()
        let (model, _) = makeModel(secrets)
        model.saveZaiKey("sk-paste", for: key)

        model.saveZaiKey("   ", for: key)

        #expect(secrets.secret(for: .tile(key)) == nil)
        #expect(model.hasZaiKey(for: key) == false)
    }

    /// A store that refuses is said out loud: a paste the user believes was
    /// taken must not quietly never have been.
    @Test func aRefusedPasteIsSaidNotSwallowed() {
        let (model, _) = makeModel(LockedSecretStore())

        #expect(model.saveZaiKey("sk-paste", for: key) == .refused)
        #expect(model.hasZaiKey(for: key) == false)
    }

    @Test func aTakenPasteIsConfirmed() {
        let (model, _) = makeModel()

        #expect(model.saveZaiKey("sk-paste", for: key) == .saved)
        #expect(model.saveZaiKey("", for: key) == .removed)
    }

    /// No config yet — a tile created before its first paste — still saves:
    /// the handle is derived, so there is nothing to read back first.
    @Test func theFirstPasteBringsItsOwnConfig() throws {
        let (model, defaults) = makeModel()

        model.saveZaiKey("sk-paste", for: key)

        let record = try #require(storedRecords(defaults).first { $0.key == key })
        #expect(record.config?.key != nil)
        #expect(record.policy.refreshSeconds == Int(TileDefaults.codeUsage.refresh))
    }
}
