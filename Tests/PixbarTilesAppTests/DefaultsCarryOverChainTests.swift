import Foundation
import Testing
@testable import PixbarTilesApp

// The app has been renamed twice: AwtrixConnectors, then PixelClockTiles, now
// PixbarTiles — three bundle identifiers, three defaults domains. A user can
// arrive from either earlier one, and must, with everything: tiles, clocks,
// snapshots, the overlay the clock was lent. Every test here runs on suites of
// its own; the real domains are never read or written.

/// Three fresh suites standing in for the oldest domain, the one in between and
/// the new one, all removed when `body` returns.
private func withThreeDomains(
    _ body: (
        _ oldest: UserDefaults, _ between: UserDefaults, _ new: String, _ newDefaults: UserDefaults,
        _ chain: [DefaultsCarryOver.Step]
    ) throws -> Void
) throws {
    let oldest = "carry-chain-oldest-\(UUID().uuidString)"
    let between = "carry-chain-between-\(UUID().uuidString)"
    let new = "carry-chain-new-\(UUID().uuidString)"
    let oldestDefaults = try #require(UserDefaults(suiteName: oldest))
    let betweenDefaults = try #require(UserDefaults(suiteName: between))
    let newDefaults = try #require(UserDefaults(suiteName: new))
    defer {
        oldestDefaults.removePersistentDomain(forName: oldest)
        betweenDefaults.removePersistentDomain(forName: between)
        newDefaults.removePersistentDomain(forName: new)
    }
    // Newest first, with the real markers: the marker the oldest hop writes is
    // what the domain in between carries once its own copy has run.
    let chain = [
        DefaultsCarryOver.Step(domain: between, doneKey: DefaultsCarryOver.renamedDoneKey),
        DefaultsCarryOver.Step(domain: oldest, doneKey: DefaultsCarryOver.doneKey),
    ]
    try body(oldestDefaults, betweenDefaults, new, newDefaults, chain)
}

// A user on the PixelClockTiles build: everything it holds arrives. Its domain
// also carries the marker of its own carry-over from AwtrixConnectors, so the
// oldest domain — read once already, long ago — is not read again: its
// `panelWidth` was since removed by the user, and must stay removed.
@Test func aUserOnTheDomainBeforeArrivesWithEverything() throws {
    try withThreeDomains { oldest, between, new, newDefaults, chain in
        let tiles = Data(#"[{"id":"weather"}]"#.utf8)
        oldest.set("192.168.1.72", forKey: "deviceHost")
        oldest.set(480, forKey: "panelWidth")
        between.set("10.0.0.5", forKey: "deviceHost")
        between.set(tiles, forKey: "tiles")
        between.set(["pct-weather"], forKey: "ownedApps.clock-1")
        between.set(true, forKey: DefaultsCarryOver.doneKey)

        DefaultsCarryOver.run(chain, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.string(forKey: "deviceHost") == "10.0.0.5")
        #expect(relaunched.data(forKey: "tiles") == tiles)
        #expect(relaunched.stringArray(forKey: "ownedApps.clock-1") == ["pct-weather"])
        #expect(relaunched.object(forKey: "panelWidth") == nil)
    }
}

// A user who went from AwtrixConnectors straight to this build never had a
// PixelClockTiles domain. The empty hop costs nothing and the oldest one still
// brings everything across.
@Test func aUserStillOnTheOldestDomainArrivesToo() throws {
    try withThreeDomains { oldest, _, new, newDefaults, chain in
        oldest.set("192.168.1.72", forKey: "deviceHost")
        oldest.set(480, forKey: "panelWidth")

        DefaultsCarryOver.run(chain, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.string(forKey: "deviceHost") == "192.168.1.72")
        #expect(relaunched.integer(forKey: "panelWidth") == 480)
    }
}

// Whatever the new build has already written is newer than either old domain.
@Test func aKeyTheNewDomainHoldsKeepsItsValueAcrossTheChain() throws {
    try withThreeDomains { oldest, between, new, newDefaults, chain in
        oldest.set("192.168.1.72", forKey: "deviceHost")
        between.set("10.0.0.5", forKey: "deviceHost")
        newDefaults.set("10.0.0.9", forKey: "deviceHost")

        DefaultsCarryOver.run(chain, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.string(forKey: "deviceHost") == "10.0.0.9")
    }
}

// Once, for every hop: a key added to an old domain after the first launch of
// this build is never pulled in.
@Test func theChainRunsOnceAndNeverAgain() throws {
    try withThreeDomains { oldest, between, new, newDefaults, chain in
        between.set("10.0.0.5", forKey: "deviceHost")
        DefaultsCarryOver.run(chain, into: new, through: newDefaults)

        between.set(480, forKey: "panelWidth")
        oldest.set(true, forKey: "weatherEnabled")
        DefaultsCarryOver.run(chain, into: new, through: newDefaults)

        let relaunched = try #require(UserDefaults(suiteName: new))
        #expect(relaunched.object(forKey: "panelWidth") == nil)
        #expect(relaunched.object(forKey: "weatherEnabled") == nil)
        let written = try #require(newDefaults.persistentDomain(forName: new))
        #expect(written[DefaultsCarryOver.renamedDoneKey] as? Bool == true)
        #expect(written[DefaultsCarryOver.doneKey] as? Bool == true)
    }
}

@Test func withNoBundleIdentifierTheChainWritesNothing() throws {
    try withThreeDomains { _, between, new, newDefaults, chain in
        between.set("10.0.0.5", forKey: "deviceHost")

        DefaultsCarryOver.run(chain, into: nil, through: newDefaults)

        #expect(newDefaults.persistentDomain(forName: new)?.isEmpty ?? true)
    }
}

// The literals the chain depends on, newest first. A typo passes every test
// above, which run on suites, and loses every setting on the real machine.
@Test func theChainIsTheTwoDomainsTheAppShippedUnder() {
    #expect(DefaultsCarryOver.chain == [
        DefaultsCarryOver.Step(domain: "dev.artk0re.pixelclocktiles", doneKey: "carriedOverFromPixelClockTiles"),
        DefaultsCarryOver.Step(domain: "dev.artk0re.awtrix-connectors", doneKey: "carriedOverFromAwtrixConnectors"),
    ])
}
