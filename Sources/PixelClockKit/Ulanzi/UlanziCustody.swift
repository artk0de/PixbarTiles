import Foundation

/// The durable record of custom-app names we own, one name per tile (D9).
/// TC002 apps outlive our process, so the record must too — unlike the AWTRIX
/// custody, which is in-memory by design because AWTRIX apps do not outlive
/// their sender. The two stay separate on purpose.
public protocol UlanziAppRecord: Sendable {
    func names(forClock clockId: String) -> [String]
    func save(_ names: [String], forClock clockId: String)
}

/// UserDefaults-backed record. Every clock's names live under
/// `"ownedApps.<clockId>"` as an ordered list — ordered, so claims come back
/// in the order they were made and pages read the same after a restart.
///
/// `@unchecked` because `UserDefaults` is not declared `Sendable` — the
/// conformance is unsound in principle and thread-safe in fact: the store is
/// immutable after init and `UserDefaults` itself is documented as thread-safe.
public struct UserDefaultsAppRecord: UlanziAppRecord, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func names(forClock clockId: String) -> [String] {
        defaults.stringArray(forKey: Self.key(clockId)) ?? []
    }

    public func save(_ names: [String], forClock clockId: String) {
        defaults.set(names, forKey: Self.key(clockId))
    }

    private static func key(_ clockId: String) -> String { "ownedApps.\(clockId)" }
}

public actor UlanziCustody {
    /// DIY pages 100–120 (research §6) — the hard budget of custom apps one
    /// clock carries, and therefore of names we may claim on it (D7).
    private static let maxApps = 21

    private let device: UlanziDevice
    private let record: any UlanziAppRecord
    private let clockId: String

    public init(device: UlanziDevice, record: any UlanziAppRecord, clockId: String) {
        self.device = device
        self.record = record
        self.clockId = clockId
    }

    /// The tile's page name: `pct-<tileId>` (D10).
    private func tileName(_ tileId: String) -> String { Self.pageName(forTile: tileId) }

    /// The name a tile's page lives under, without claiming it — for reading
    /// the clock's page list against.
    public static func pageName(forTile tileId: String) -> String { "pct-\(tileId)" }

    /// The name this tile's page lives under, claiming it on first use. The
    /// claim is bookkeeping only — the device hears the name at the first
    /// upsert — and a claim beyond the DIY budget throws rather than silently
    /// replacing somebody else's page.
    public func appName(forTile tileId: String) throws -> String {
        let name = tileName(tileId)
        var owned = record.names(forClock: clockId)
        if !owned.contains(name) {
            guard owned.count < Self.maxApps else {
                throw UlanziError.limit(
                    "the clock carries at most \(Self.maxApps) custom apps; \"\(name)\" has no page"
                )
            }
            owned.append(name)
            record.save(owned, forClock: clockId)
        }
        return name
    }

    public var ownedNames: [String] { record.names(forClock: clockId) }

    /// The tile's page name while the clock actually lists it, or nil — a
    /// tile added a moment ago, or a page a reboot wiped, has nothing on the
    /// clock to show. Read-only: nothing is claimed.
    public func listedPage(forTile tileId: String) async throws -> String? {
        let name = tileName(tileId)
        return try await device.customApps().contains(name) ? name : nil
    }

    /// Startup sweep: names we claim that the device no longer lists leave the
    /// record silently (nothing to delete — a reboot likely wiped them, E9);
    /// names the device still lists but no live tile uses get an empty-body
    /// delete. Stale names from crashes or older builds leave the knob cycle
    /// here (D4, D10).
    public func sweep(liveTiles: [String]) async throws {
        let listed = try await device.customApps()
        let expected = Set(liveTiles.map(tileName))
        let owned = record.names(forClock: clockId)

        // Still on the device but no live tile behind it: take the page back.
        for name in owned where listed.contains(name) && !expected.contains(name) {
            try await device.removeApp(named: name)
        }

        // Keep exactly the names both expected and still listed. Names the
        // device lost are dropped from the record — their tiles re-claim on
        // their next delivery, which re-creates the app by upsert.
        let surviving = owned.filter { expected.contains($0) && listed.contains($0) }
        record.save(surviving, forClock: clockId)
    }

    /// Quit or last-tile removal: an empty-body delete for every owned name,
    /// then the record cleared. The pages leave the knob cycle, which is the
    /// user-initiated ending (D4, E4 unverified on hardware).
    public func releaseAll() async throws {
        for name in record.names(forClock: clockId) {
            try await device.removeApp(named: name)
        }
        record.save([], forClock: clockId)
    }

    /// One tile's page: the empty-body delete for its name, then the record
    /// without it. A name this clock never claimed has nothing to release.
    public func release(tileId: String) async throws {
        let name = tileName(tileId)
        var owned = record.names(forClock: clockId)
        guard owned.contains(name) else { return }
        try await device.removeApp(named: name)
        owned.removeAll { $0 == name }
        record.save(owned, forClock: clockId)
    }
}
