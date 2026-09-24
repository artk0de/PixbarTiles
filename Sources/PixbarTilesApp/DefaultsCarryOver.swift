import Foundation

/// The settings this app kept under the names it shipped with before, copied
/// once into the domain it reads now.
///
/// macOS keys a defaults domain by bundle identifier, and the app has had
/// three: `dev.artk0re.awtrix-connectors`, then `dev.artk0re.pixelclocktiles`,
/// now `dev.artk0re.pixbartiles`. Each move would otherwise start everything
/// from scratch: the clock's address, the tiles and clocks, each connector's
/// cadence and last delivery, the battery history the trend is rebuilt from,
/// and the record of the overlay the clock was lent — the one value that
/// exists nowhere else.
///
/// Three rules, each of which a test pins:
///
/// - **Gaps only.** A key the new domain already holds is newer than anything
///   the old one left, so it is never overwritten.
/// - **Once.** A copy on every launch would bring back keys the app has since
///   removed — a borrowed-overlay record re-imported after the clock got its
///   value back would hand the clock an overlay from weeks ago.
/// - **The marker last.** A launch that dies part-way leaves no marker, and the
///   next one starts again; the first rule makes starting again free.
///
/// The old domains are read and never written, so going back to an old build
/// finds everything where it was.
///
/// The previous names run as a `chain`, newest first. A user on the
/// PixelClockTiles build brings its domain across, and with it that domain's
/// own marker for the AwtrixConnectors copy it once made — so the oldest domain
/// is skipped rather than read a second time. A user who went from
/// AwtrixConnectors straight to this build has no PixelClockTiles domain: that
/// hop copies nothing, and the oldest one brings everything.
enum DefaultsCarryOver {
    /// One previous domain and the marker that says it has been copied.
    struct Step: Equatable {
        let domain: String
        let doneKey: String
    }

    /// The domain the app wrote to as AwtrixConnectors.
    static let previousDomain = "dev.artk0re.awtrix-connectors"

    /// Set in the new domain once the copy has run, whatever it found.
    static let doneKey = "carriedOverFromAwtrixConnectors"

    /// The domain the app wrote to as PixelClockTiles. The old name on purpose:
    /// it is where those settings are.
    static let renamedDomain = "dev.artk0re.pixelclocktiles"

    /// Set in the new domain once the PixelClockTiles domain has been copied.
    static let renamedDoneKey = "carriedOverFromPixelClockTiles"

    /// Every previous domain, newest first — the order that lets a newer value
    /// fill a gap before an older one can.
    static let chain = [
        Step(domain: renamedDomain, doneKey: renamedDoneKey),
        Step(domain: previousDomain, doneKey: doneKey),
    ]

    /// The writes a carry-over makes, in the order it makes them: every key of
    /// `previous` that `current` lacks, then the marker. Empty once the marker
    /// is in `current`.
    ///
    /// Both arguments are persistent domains — what each domain holds of its
    /// own — and never a read through the search list. That list also answers
    /// from the registration domain and from `NSGlobalDomain`, so a registered
    /// default, or a per-app `AppleLanguages` the global domain carries too,
    /// would pass for a value the user set and theirs would be left behind.
    ///
    /// Sorted by key only so the order is the same on every run; nothing reads
    /// the keys in order.
    static func writes(
        previous: [String: Any], current: [String: Any], doneKey: String = doneKey
    ) -> [(key: String, value: Any)] {
        guard current[doneKey] == nil else { return [] }
        let carried = previous
            .filter { current[$0.key] == nil }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
        return carried + [(key: doneKey, value: true)]
    }

    /// Copies `previous` into `current` through `defaults`, which must be the
    /// instance whose domain `current` names — `.standard` in the app.
    ///
    /// `current` is the bundle identifier, and nil means there is none: a bare
    /// `swift run`, which is not the bundle's first launch and has no domain of
    /// the bundle's to carry anything into. Marking it would make the real
    /// first launch skip the copy, so nothing is written at all.
    static func run(
        from previous: String, into current: String?, through defaults: UserDefaults,
        doneKey: String = doneKey
    ) {
        guard let current else { return }
        let pending = writes(
            previous: defaults.persistentDomain(forName: previous) ?? [:],
            current: defaults.persistentDomain(forName: current) ?? [:],
            doneKey: doneKey
        )
        for (key, value) in pending {
            defaults.set(value, forKey: key)
        }
    }

    /// Runs every step of `chain` in order into `current`. Each step reads the
    /// new domain afresh, so the markers an earlier step carried across decide
    /// whether a later one runs at all.
    static func run(_ chain: [Step] = chain, into current: String?, through defaults: UserDefaults) {
        for step in chain {
            run(from: step.domain, into: current, through: defaults, doneKey: step.doneKey)
        }
    }
}
