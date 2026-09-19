import Foundation

/// The clocks, as one JSON array under one `UserDefaults` key.
public final class ClockStore: @unchecked Sendable {
    public static let key = "clocks"

    /// Static, for the reason `UserDefaultsUploadedIconStore`'s lock is:
    /// what is guarded is a key in a defaults domain, and two instances with a
    /// lock each lose updates as if they had none.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// In stored order. A key that does not decode reads as no clocks.
    public func all() -> [ClockRecord] {
        Self.lock.withLock { stored() }
    }

    /// Replaces every clock.
    ///
    /// Throws when the list cannot be encoded rather than writing nothing and
    /// returning, so a migration cannot write its marker over a write that
    /// did not happen.
    public func replaceAll(_ clocks: [ClockRecord]) throws {
        let data = try JSONEncoder().encode(clocks)
        Self.lock.withLock { defaults.set(data, forKey: Self.key) }
    }

    /// Applies `change` to the stored clock with `clock`'s id, or stores
    /// `clock` with the change applied when there is none.
    ///
    /// The change lands on what is STORED, not on `clock`. A model's copy is
    /// this launch's, and the stored address may already hold one typed for
    /// the next launch: writing the copy back would put the old address over
    /// it on the next poll.
    public func update(_ clock: ClockRecord, _ change: (inout ClockRecord) -> Void) {
        Self.lock.withLock {
            var clocks = stored()
            if let index = clocks.firstIndex(where: { $0.id == clock.id }) {
                change(&clocks[index])
            } else {
                var inserted = clock
                change(&inserted)
                clocks.append(inserted)
            }
            write(clocks)
        }
    }

    /// The clock a launch drives: the first one stored, or an AWTRIX clock at
    /// `address` when none is — stored before it is returned, so that what
    /// the launch learns about it has a record to land on.
    public func firstClock(orCreatingAt address: String) -> ClockRecord {
        Self.lock.withLock {
            if let first = stored().first { return first }
            let created = ClockRecord(name: "Clock", model: .awtrix3, address: address)
            write([created])
            return created
        }
    }

    private func stored() -> [ClockRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([ClockRecord].self, from: data)) ?? []
    }

    private func write(_ clocks: [ClockRecord]) {
        guard let data = try? JSONEncoder().encode(clocks) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
