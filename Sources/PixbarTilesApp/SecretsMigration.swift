import Foundation
import PixbarKit

/// The half of the login keychain the move needs: read an item, then delete
/// it. A protocol so the suite counts the calls on a stub — no test may reach
/// the user's real keychain.
protocol LegacyKeychainReading {
    func key(for account: String) -> String?
    func removeKey(for account: String) throws
}

extension LoginKeychainStore: LegacyKeychainReading {}

/// Moves every z.ai key out of the login keychain into the secret store, once.
///
/// The keychain asks for the password after every re-sign of an ad-hoc app;
/// one last prompt here is the price of never seeing it again and of not
/// pasting the key a second time.
///
/// The keychain item goes only after the store took its copy. A key the
/// keychain will not give up — the prompt refused, the item already gone — is
/// left where it is and the marker is still set: the tile reads "no key",
/// which is the state it would be in after any other loss, and a refused
/// prompt is not asked again at every launch.
struct SecretsMigration {
    static let markerKey = "migration.secretsToFile"

    let defaults: UserDefaults
    let keychain: any LegacyKeychainReading
    let secrets: any SecretStoring

    func run() {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        for record in TileStore(defaults: defaults).all() {
            // The record names the keychain account; the store files the key
            // under the tile itself, instance included.
            guard let handle = record.config?.key,
                  let key = keychain.key(for: handle.keyAccount), !key.isEmpty
            else { continue }
            do {
                try secrets.save(key, for: .tile(record.key))
            } catch {
                continue
            }
            try? keychain.removeKey(for: handle.keyAccount)
        }
        defaults.set(true, forKey: Self.markerKey)
    }
}
