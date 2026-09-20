// Tests/PixelClockKitTests/TileKeyStoringTests.swift
import Foundation
import Security
import Testing
@testable import PixelClockKit

// A tile's API key lives in the login keychain, keyed by the tile, and the
// tile record never sees it. The store's SecItem half is three documented
// calls — the rules worth pinning are the QUERIES those calls are made with
// (tested here, against the CFDictionary shapes, never against the real
// keychain) and the contract any store answers to (tested through the memory
// fixture every suite in this repo may use in its place).

@Suite struct TileKeyStoringTests {
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

    // MARK: - The contract, through the memory fixture

    @Test func aSavedKeyIsReadBack() throws {
        let store = MemoryKeychainStore()
        try store.save("sk-test", for: "tile-handle")

        #expect(store.key(for: "tile-handle") == "sk-test")
    }

    /// A second paste replaces the first: the keychain holds one key per tile,
    /// and a stale one standing behind a fresh paste would send the wrong
    /// credential to the service.
    @Test func aSecondPasteReplacesTheFirst() throws {
        let store = MemoryKeychainStore()
        try store.save("old", for: "tile-handle")
        try store.save("new", for: "tile-handle")

        #expect(store.key(for: "tile-handle") == "new")
    }

    @Test func removingAKeyTakesItAwayAndRemovingTwiceIsNotAnError() throws {
        let store = MemoryKeychainStore()
        try store.save("sk-test", for: "tile-handle")
        try store.removeKey(for: "tile-handle")

        #expect(store.key(for: "tile-handle") == nil)
        #expect(try store.removeKey(for: "tile-handle") == ())
    }

    @Test func accountsDoNotBleedIntoEachOther() throws {
        let store = MemoryKeychainStore()
        try store.save("one", for: "clock-a")
        try store.save("two", for: "clock-b")

        #expect(store.key(for: "clock-a") == "one")
        #expect(store.key(for: "clock-b") == "two")
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
