// Sources/PixbarKit/Secrets/EncryptedFileSecretStore.swift
import CryptoKit
import Darwin
import Foundation

/// The app's secrets in one file, sealed with a key only this Mac can derive.
///
/// The file is `"PCTS"`, a version byte, then an AES-GCM sealed box (nonce,
/// ciphertext, tag) over a JSON map from `SecretAccount.storageKey` to the
/// secret. The key is HKDF-SHA256 over the hardware UUID with a compiled-in
/// salt, so opening the file needs this app AND this machine: a backup or a
/// synced copy is noise anywhere else. Unlike the login keychain, reading it
/// raises no prompt, which is what an app rebuilt with a new signature needs.
///
/// Every read opens the file afresh — no cache, so a paste is live at the
/// next poll — and the lock keeps a read from seeing a write half done.
public final class EncryptedFileSecretStore: SecretStoring, @unchecked Sendable {
    static let magic = Data("PCTS".utf8)
    static let version: UInt8 = 1
    /// Compiled in so the key needs the app AND the machine; not a secret on its own.
    static let salt = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
    /// The app's name before the rename to PixbarTiles, and it stays: it is
    /// HKDF input, so a different string derives a different key, and every
    /// `secrets.enc` written so far — every token the user pasted — would no
    /// longer open. It names the key, not the app.
    static let info = Data("PixelClockTiles secrets v1".utf8)

    private let fileURL: URL
    private let hardwareId: @Sendable () -> String?
    private let lock = NSLock()

    public init(fileURL: URL, hardwareId: @escaping @Sendable () -> String?) {
        self.fileURL = fileURL
        self.hardwareId = hardwareId
    }

    /// The file the app runs on: `Application Support/PixbarTiles/secrets.enc`.
    /// `SupportFolder.carryOver` moves an older installation's folder here
    /// before the first read.
    public static var liveFile: URL {
        SupportFolder.current.appendingPathComponent("secrets.enc")
    }

    /// The store the app runs on, at `liveFile`, keyed by the firmware's
    /// platform UUID.
    public static func live() -> EncryptedFileSecretStore {
        EncryptedFileSecretStore(
            fileURL: liveFile,
            hardwareId: { HardwareIdentity.platformUUID() }
        )
    }

    public func secret(for account: SecretAccount) -> String? {
        lock.withLock { load()[account.storageKey] }
    }

    public func save(_ secret: String, for account: SecretAccount) throws {
        try lock.withLock {
            var map = load()
            map[account.storageKey] = secret
            try store(map)
        }
    }

    public func remove(for account: SecretAccount) throws {
        try lock.withLock {
            var map = load()
            guard map.removeValue(forKey: account.storageKey) != nil else { return }
            try store(map)
        }
    }

    // MARK: - The file

    /// Nil without a hardware id: a key derived from nothing would be the same
    /// key on every Mac, which is worse than no store at all.
    private func key() -> SymmetricKey? {
        guard let id = hardwareId(), !id.isEmpty else { return nil }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(id.utf8)),
            salt: Self.salt, info: Self.info, outputByteCount: 32
        )
    }

    /// Every failure to open reads as "no secrets": a secret that cannot be
    /// read is one the user pastes again, and refusing to start is worse. The
    /// next save writes a whole new file over whatever was there.
    private func load() -> [String: String] {
        guard let key = key(), let bytes = try? Data(contentsOf: fileURL),
              bytes.count > Self.magic.count + 1,
              bytes.prefix(Self.magic.count) == Self.magic,
              bytes[bytes.startIndex + Self.magic.count] == Self.version,
              let box = try? AES.GCM.SealedBox(combined: bytes.dropFirst(Self.magic.count + 1)),
              let plain = try? AES.GCM.open(box, using: key),
              let map = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return [:] }
        return map
    }

    /// Seals the map and puts it in place in one step: written owner-only
    /// beside the file, then renamed over it, so a crash leaves the old file
    /// or the new one and never half of either. `rename(2)` rather than
    /// `FileManager.replaceItemAt`, which refuses when there is no file yet
    /// to replace — and the first save is exactly that case.
    private func store(_ map: [String: String]) throws {
        guard let key = key() else { throw SecretStoreError(reason: "no hardware identity") }
        let plain = try JSONEncoder().encode(map)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
            throw SecretStoreError(reason: "seal produced no combined form")
        }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staged.path,
            contents: Self.magic + Data([Self.version]) + sealed,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SecretStoreError(reason: "could not write \(staged.lastPathComponent)")
        }
        guard rename(staged.path, fileURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw SecretStoreError(reason: "could not move the file in place: \(reason)")
        }
    }
}
