import Foundation

/// The icons this app put on the device's flash, by name.
///
/// Recorded at the moment of the upload because it is not knowable afterwards.
/// `CatalogueIconInstaller` writes `/ICONS/<id>.gif` under the catalogue's bare
/// id, and that is deliberate rather than an oversight — it is what lets the
/// skip-by-name check reuse an icon the user installed themselves, which a
/// prefix like `awx-` would forfeit. The cost of that choice is that the flash
/// cannot say who wrote a file, so removal cannot be "delete everything that
/// looks like ours". This is the record that makes it "delete exactly what we
/// wrote".
///
/// Durable, because the icons outlive the process: they survive quit and
/// relaunch on purpose, so the record has to as well.
public protocol UploadedIconStore: Sendable {
    /// In upload order, each name once.
    func uploadedIcons() -> [String]
    func record(_ name: String)
    func forget(_ name: String)
}

public final class InMemoryUploadedIconStore: UploadedIconStore, @unchecked Sendable {
    private var storage: [String] = []
    private let lock = NSLock()

    public init() {}

    public func uploadedIcons() -> [String] {
        lock.withLock { storage }
    }

    public func record(_ name: String) {
        lock.withLock {
            guard !storage.contains(name) else { return }
            storage.append(name)
        }
    }

    public func forget(_ name: String) {
        lock.withLock { storage.removeAll { $0 == name } }
    }
}

public final class UserDefaultsUploadedIconStore: UploadedIconStore, @unchecked Sendable {
    /// One key for the whole record, unlike `UserDefaultsSettingsStore`'s key
    /// per connector. The reason the settings are split is that they are read
    /// one connector at a time and a shared key would couple them; this is read
    /// all at once, by the one action that removes all of it.
    private static let key = "uploadedIcons"

    private let defaults: UserDefaults
    /// Both mutators read, modify and write, which `UserDefaults` does not make
    /// atomic for us. Two installs finishing at once would otherwise write each
    /// other's list back and lose a record — an icon left on the flash that
    /// nothing in this app can name again. Its in-memory sibling has always
    /// locked; the asymmetry was the tell.
    ///
    /// Static, not per instance. What is being guarded is a key in a defaults
    /// domain, and two instances over one domain are two locks over one file —
    /// which measured at 95 lost records in 200 while a single instance lost
    /// none. The thing that can be shared is the only thing worth locking on,
    /// and there is one connector's worth of traffic through it.
    private static let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func uploadedIcons() -> [String] {
        Self.lock.withLock { stored() }
    }

    public func record(_ name: String) {
        Self.lock.withLock {
            var names = stored()
            guard !names.contains(name) else { return }
            names.append(name)
            defaults.set(names, forKey: Self.key)
        }
    }

    public func forget(_ name: String) {
        Self.lock.withLock {
            defaults.set(stored().filter { $0 != name }, forKey: Self.key)
        }
    }

    /// Read under the lock by every caller above. A value of another type reads
    /// as no record at all, which is the safe direction: nothing is removed.
    private func stored() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }
}
