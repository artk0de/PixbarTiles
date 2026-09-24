// Tests/PixbarKitTests/EncryptedFileSecretStoreTests.swift
import Foundation
import Testing
@testable import PixbarKit

// The file store's own rules, beyond the contract: the file opens only on the
// machine that wrote it, it holds nothing in the clear, it is the owner's
// alone, and every state it cannot read reads as no secrets rather than a
// failure to start.

@Suite struct EncryptedFileSecretStoreTests {
    func tmpFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("secrets.enc")
    }

    @Test func aFileWrittenOnOneMachineDoesNotOpenOnAnother() throws {
        let url = tmpFile()
        try EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
            .save("ghp_x", for: .connector("github"))
        #expect(EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-2" })
            .secret(for: .connector("github")) == nil)
        #expect(EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
            .secret(for: .connector("github")) == "ghp_x")
    }

    @Test func theSecretIsNotOnDiskInTheClear() throws {
        let url = tmpFile()
        try EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
            .save("ghp_secret_value", for: .connector("github"))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.prefix(5) == Data("PCTS".utf8) + Data([1]))
        #expect(bytes.range(of: Data("ghp_secret_value".utf8)) == nil)
    }

    @Test func aTruncatedFileReadsAsNoSecretsAndTheNextSaveReplacesIt() throws {
        let url = tmpFile()
        let store = EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
        try store.save("a", for: .connector("github"))
        try Data(contentsOf: url).prefix(9).write(to: url)
        #expect(store.secret(for: .connector("github")) == nil)
        try store.save("b", for: .connector("github"))
        #expect(store.secret(for: .connector("github")) == "b")
    }

    @Test func anUnknownVersionReadsAsNoSecrets() throws {
        let url = tmpFile()
        let store = EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
        try store.save("a", for: .connector("github"))
        var bytes = try Data(contentsOf: url)
        bytes[4] = 9
        try bytes.write(to: url)
        #expect(store.secret(for: .connector("github")) == nil)
    }

    @Test func theFileIsOwnerOnly() throws {
        let url = tmpFile()
        try EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" }).save("a", for: .connector("github"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func noHardwareIdRefusesToSaveRatherThanWritingAWeakKey() {
        let store = EncryptedFileSecretStore(fileURL: tmpFile(), hardwareId: { nil })
        #expect(throws: SecretStoreError.self) { try store.save("a", for: .connector("github")) }
        #expect(store.secret(for: .connector("github")) == nil)
    }

    @Test func tileAndConnectorAccountsDoNotCollide() throws {
        let store = EncryptedFileSecretStore(fileURL: tmpFile(), hardwareId: { "HW-1" })
        let key = TileKey(clockId: UUID(), connectorId: "github", instance: "")
        try store.save("tile", for: .tile(key))
        try store.save("conn", for: .connector("github"))
        #expect(store.secret(for: .tile(key)) == "tile")
        #expect(store.secret(for: .connector("github")) == "conn")
    }
}
