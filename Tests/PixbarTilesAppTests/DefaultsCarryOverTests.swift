import Foundation
import Testing
@testable import PixbarTilesApp

// macOS keys a defaults domain by bundle identifier, so the move from
// `dev.artk0re.awtrix-connectors` to `dev.artk0re.pixelclocktiles` would start
// every setting from scratch: the clock's address, each connector's cadence and
// last delivery, the battery history, the overlay the clock was lent. The copy
// is what keeps an existing installation where it was. Every test here runs on
// two suites of its own; the real domains are never read or written.

/// Two fresh suites standing in for the old domain and the new one, both
/// removed when `body` returns.
///
/// `newDefaults` is the instance the copy runs through, as `.standard` is in the
/// app. Reads after the copy go through a second instance on the same suite,
/// which is what the next launch does.
private func withTwoDomains(
    _ body: (_ old: String, _ oldDefaults: UserDefaults, _ new: String, _ newDefaults: UserDefaults) throws -> Void
) throws {
    let old = "carry-over-old-\(UUID().uuidString)"
    let new = "carry-over-new-\(UUID().uuidString)"
    let oldDefaults = try #require(UserDefaults(suiteName: old))
    let newDefaults = try #require(UserDefaults(suiteName: new))
    defer {
        oldDefaults.removePersistentDomain(forName: old)
        newDefaults.removePersistentDomain(forName: new)
    }
    try body(old, oldDefaults, new, newDefaults)
}

// MARK: - What is copied

// The shapes the app actually stores: a string (the address), an integer (the
// panel's width, typed by hand with `defaults write … -int`), a bool (a
// connector switch) and data (the JSON records). Each has to arrive as what it
// was, or the reader on the other side falls back to its default.
@Test func everyKeyTheOldDomainHeldArrivesInTheNewOne() throws {
    try withTwoDomains { old, oldDefaults, new, newDefaults in
        let record = Data(#"{"isEnabled":true}"#.utf8)
        oldDefaults.set("192.168.1.72", forKey: "deviceHost")
        oldDefaults.set(480, forKey: "panelWidth")
        oldDefaults.set(true, forKey: "weatherEnabled")
        oldDefaults.set(record, forKey: "connector.anecdotes")

        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.string(forKey: "deviceHost") == "192.168.1.72")
        #expect(relaunched.integer(forKey: "panelWidth") == 480)
        #expect(relaunched.object(forKey: "weatherEnabled") as? Bool == true)
        #expect(relaunched.data(forKey: "connector.anecdotes") == record)
    }
}

// Whatever the new app has already written is newer than anything the old one
// left behind, so the copy fills gaps and nothing else. The second key is there
// so that a copy which wrote nothing at all could not pass.
@Test func aKeyTheNewDomainAlreadyHoldsKeepsItsValue() throws {
    try withTwoDomains { old, oldDefaults, new, newDefaults in
        oldDefaults.set("192.168.1.72", forKey: "deviceHost")
        oldDefaults.set(480, forKey: "panelWidth")
        newDefaults.set("10.0.0.9", forKey: "deviceHost")

        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.string(forKey: "deviceHost") == "10.0.0.9")
        #expect(relaunched.integer(forKey: "panelWidth") == 480)
    }
}

// "Already holds" means the new domain's own record, not whatever a read of the
// key answers. A read also answers from the registration domain and from
// `NSGlobalDomain`, so a registered default — or a per-app `AppleLanguages`
// that the global domain also carries — would pass for a value the user set,
// and the one they did set would be left behind.
//
// The key is this test's own: the registration domain belongs to the process,
// not to the instance it is registered through, and it cannot be taken back —
// a registered `panelWidth` would answer every other test's read of it.
@Test func aValueTheNewDomainOnlyHasByDefaultIsStillCarriedOver() throws {
    let key = "carry-over-registered-\(UUID().uuidString)"
    try withTwoDomains { old, oldDefaults, new, newDefaults in
        oldDefaults.set(480, forKey: key)
        newDefaults.register(defaults: [key: 320])

        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        let written = try #require(newDefaults.persistentDomain(forName: new))
        #expect(written[key] as? Int == 480)
    }
}

// MARK: - Once

// Once means once. A copy on every launch would bring back every key the new
// app has since removed: the borrowed-overlay record is deleted once the clock
// has its value back, and a stale one re-imported at each start would have the
// app hand the clock an overlay from weeks ago.
@Test func theCopyRunsOnceAndNeverAgain() throws {
    try withTwoDomains { old, oldDefaults, new, newDefaults in
        oldDefaults.set("192.168.1.72", forKey: "deviceHost")
        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        oldDefaults.set(480, forKey: "panelWidth")
        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.object(forKey: "panelWidth") == nil)
    }
}

// The marker is written after every key, so a launch that dies part-way leaves
// no marker and the next one starts the copy again. Keys that did arrive are
// skipped by the rule above, so starting again costs nothing.
@Test func theMarkerIsTheLastThingWritten() {
    let writes = DefaultsCarryOver.writes(
        previous: ["deviceHost": "192.168.1.72", "panelWidth": 480],
        current: [:]
    )

    #expect(writes.map(\.key) == ["deviceHost", "panelWidth", DefaultsCarryOver.doneKey])
}

// A copy cut short resumes: what arrived last time is not written again, what
// did not is, and the marker still comes last.
@Test func aCopyCutShortWritesOnlyWhatIsStillMissing() {
    let writes = DefaultsCarryOver.writes(
        previous: ["deviceHost": "192.168.1.72", "panelWidth": 480],
        current: ["deviceHost": "192.168.1.72"]
    )

    #expect(writes.map(\.key) == ["panelWidth", DefaultsCarryOver.doneKey])
}

@Test func aCopyAlreadyMarkedDoneWritesNothing() {
    let writes = DefaultsCarryOver.writes(
        previous: ["panelWidth": 480],
        current: [DefaultsCarryOver.doneKey: true]
    )

    #expect(writes.isEmpty)
}

// A fresh install has no old domain. The first launch is still the first
// launch, so it is marked: an old build installed afterwards must not have its
// settings pulled in on some later start.
@Test func aFreshInstallOnlyMarksTheCopyDone() throws {
    try withTwoDomains { old, _, new, newDefaults in
        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        let written = try #require(newDefaults.persistentDomain(forName: new))
        #expect(written.keys.sorted() == [DefaultsCarryOver.doneKey])
    }
}

// MARK: - What is left alone

// The old domain is read, never written. Nothing is deleted from it, so going
// back to the old build finds everything where it was.
@Test func theOldDomainIsLeftExactlyAsItWas() throws {
    try withTwoDomains { old, oldDefaults, new, newDefaults in
        oldDefaults.set("192.168.1.72", forKey: "deviceHost")
        oldDefaults.set(480, forKey: "panelWidth")
        let before = try #require(newDefaults.persistentDomain(forName: old))

        DefaultsCarryOver.run(from: old, into: new, through: newDefaults)

        let after = try #require(newDefaults.persistentDomain(forName: old))
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
    }
}

// A bare `swift run` has no bundle identifier and so no domain of its own to
// carry anything into. It is not the first launch of the bundle, and marking it
// would make the real first launch skip the copy.
@Test func withNoBundleIdentifierNothingIsWritten() throws {
    try withTwoDomains { old, oldDefaults, new, newDefaults in
        oldDefaults.set("192.168.1.72", forKey: "deviceHost")

        DefaultsCarryOver.run(from: old, into: nil, through: newDefaults)

        #expect(newDefaults.persistentDomain(forName: new)?.isEmpty ?? true)
    }
}

// The one literal the whole copy depends on. A typo here passes every other
// test, which run on suites, and loses every setting on the real machine.
@Test func theOldDomainIsTheOneTheAppShippedUnder() {
    #expect(DefaultsCarryOver.previousDomain == "dev.artk0re.awtrix-connectors")
}
