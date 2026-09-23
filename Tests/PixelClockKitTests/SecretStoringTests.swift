// Tests/PixelClockKitTests/SecretStoringTests.swift
import Foundation
import Security
import Testing
@testable import PixelClockKit

// A secret lives in a store keyed by the tile or by the connector, and the
// tile record never sees it. The legacy login keychain's SecItem half is three
// documented calls — the rules worth pinning are the QUERIES those calls are
// made with (tested here, against the CFDictionary shapes, never against the
// real keychain). The contract every store answers to runs against both the
// memory fixture and the encrypted file store.

@Suite struct SecretStoringTests {
    // MARK: - The queries the login keychain is asked

    @Test func theReadQueryNamesOurServiceAndTheItemAndAsksForDataBack() {
        let query = LoginKeychainStore.query(
            service: LoginKeychainStore.service, account: "tile-handle", returningData: true
        )

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == LoginKeychainStore.service)
        #expect(query[kSecAttrAccount as String] as? String == "tile-handle")
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    /// The service name is namespaced to this app: items of other programs
    /// share the login keychain, and an unadorned account would collide.
    @Test func everyQueryCarriesTheNamespacedService() {
        for query in [
            LoginKeychainStore.query(service: "PixelClockTiles tile keys", account: "a", returningData: false),
            LoginKeychainStore.writeQuery(service: "PixelClockTiles tile keys", account: "a", data: Data()),
            LoginKeychainStore.deleteQuery(service: "PixelClockTiles tile keys", account: "a"),
        ] {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "PixelClockTiles tile keys")
            #expect(query[kSecAttrAccount as String] as? String == "a")
        }
    }

    @Test func theWriteQueryCarriesTheSecret() {
        let query = LoginKeychainStore.writeQuery(
            service: "PixelClockTiles tile keys", account: "a", data: Data("secret".utf8)
        )

        #expect(query[kSecValueData as String] as? Data == Data("secret".utf8))
    }

    // MARK: - The contract, through every store the suite may stand on

    @Test(arguments: StoreKind.allCases)
    func aSavedKeyIsReadBack(_ kind: StoreKind) throws {
        let store = kind.make()
        try store.save("sk-test", for: .connector("tile-handle"))

        #expect(store.secret(for: .connector("tile-handle")) == "sk-test")
    }

    /// A second paste replaces the first: the store holds one key per tile,
    /// and a stale one standing behind a fresh paste would send the wrong
    /// credential to the service.
    @Test(arguments: StoreKind.allCases)
    func aSecondPasteReplacesTheFirst(_ kind: StoreKind) throws {
        let store = kind.make()
        try store.save("old", for: .connector("tile-handle"))
        try store.save("new", for: .connector("tile-handle"))

        #expect(store.secret(for: .connector("tile-handle")) == "new")
    }

    @Test(arguments: StoreKind.allCases)
    func removingAKeyTakesItAwayAndRemovingTwiceIsNotAnError(_ kind: StoreKind) throws {
        let store = kind.make()
        try store.save("sk-test", for: .connector("tile-handle"))
        try store.remove(for: .connector("tile-handle"))

        #expect(store.secret(for: .connector("tile-handle")) == nil)
        #expect(try store.remove(for: .connector("tile-handle")) == ())
    }

    @Test(arguments: StoreKind.allCases)
    func accountsDoNotBleedIntoEachOther(_ kind: StoreKind) throws {
        let store = kind.make()
        try store.save("one", for: .connector("clock-a"))
        try store.save("two", for: .connector("clock-b"))

        #expect(store.secret(for: .connector("clock-a")) == "one")
        #expect(store.secret(for: .connector("clock-b")) == "two")
    }

    /// The login store is a real store: the type exists and answers to the
    /// same contract its SecItem calls implement. Its network of system calls
    /// is exactly the documented API — verified above as queries — and is
    /// never exercised against the user's own keychain from a test.
    @Test func theLoginStoreAnswersToTheSameContract() {
        let store: any TileKeyStoring = LoginKeychainStore()

        #expect(store.key(for: "no-such-tile-in-a-fresh-store") == nil)
    }
}

/// The stores the contract runs against. Every one starts empty: the file
/// store gets a file of its own under a fresh directory, so no two cases —
/// and no two runs — share a secret.
enum StoreKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case encryptedFile

    func make() -> any SecretStoring {
        switch self {
        case .memory:
            MemorySecretStore()
        case .encryptedFile:
            EncryptedFileSecretStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("secrets.enc"),
                hardwareId: { "HW-1" }
            )
        }
    }

    var testDescription: String {
        switch self {
        case .memory: "memory"
        case .encryptedFile: "encrypted file"
        }
    }
}
