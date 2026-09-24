import Foundation
import Testing
@testable import PixbarKit

// The shape later phases decode, written out rather than produced by the
// encoder under test: a test that encodes and decodes with the same code would
// pass through any rename. Two clocks, so both raw values are pinned.
@Test func clocksAreReadFromTheShapeTheyAreStoredIn() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let desk = try #require(UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11"))
    let kitchen = try #require(UUID(uuidString: "0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D"))
    defaults.set(
        Data(
            #"""
            [{"id":"6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11","name":"Desk","model":"awtrix3",\#
            "address":"192.168.1.72","hardwareIdentity":"awtrix_a07f9c"},\#
            {"id":"0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D","name":"Kitchen",\#
            "model":"ulanziTC002","address":"192.168.1.80"}]
            """#.utf8
        ),
        forKey: "clocks"
    )

    #expect(
        ClockStore(defaults: defaults).all() == [
            ClockRecord(
                id: desk, name: "Desk", model: .awtrix3, address: "192.168.1.72",
                hardwareIdentity: "awtrix_a07f9c"
            ),
            ClockRecord(id: kitchen, name: "Kitchen", model: .ulanziTC002, address: "192.168.1.80"),
        ]
    )
}

@Test func aKeyThatDoesNotDecodeReadsAsNoClocks() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not clocks".utf8), forKey: ClockStore.key)

    #expect(ClockStore(defaults: defaults).all().isEmpty)
}

// Read back through a second store over the same defaults, because that is
// what a relaunch is.
@Test func replacedClocksSurviveARelaunchInOrder() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clocks = [
        ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5"),
        ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6"),
    ]

    try ClockStore(defaults: defaults).replaceAll(clocks)

    #expect(ClockStore(defaults: defaults).all() == clocks)
}

// The defect this shape exists to prevent. The model holds this launch's copy
// of its clock; the stored record may already carry an address typed for the
// NEXT launch. A poll writing the identity must not write the copy's address
// back over it.
@Test func anUpdateChangesTheStoredClockRatherThanTheCopyItWasGiven() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let thisLaunch = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    try store.replaceAll([thisLaunch])
    store.update(thisLaunch) { $0.address = "10.0.0.9" }

    store.update(thisLaunch) { $0.hardwareIdentity = "abc" }

    let stored = try #require(store.all().first)
    #expect(stored.address == "10.0.0.9")
    #expect(stored.hardwareIdentity == "abc")
}

@Test func anUpdateStoresAClockThatWasNotStoredYet() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")

    store.update(clock) { $0.hardwareIdentity = "abc" }

    var expected = clock
    expected.hardwareIdentity = "abc"
    #expect(store.all() == [expected])
}

@Test func anUpdateLeavesTheOtherClocksAsTheyWere() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
    try store.replaceAll([desk, kitchen])

    store.update(kitchen) { $0.address = "10.0.0.7" }

    #expect(store.all().first == desk)
    #expect(store.all().last?.address == "10.0.0.7")
}

// What a launch with nothing stored drives: nothing. The empty state is the
// user's to answer — the store invents no clock at a guessed address (D6).
@Test func aLaunchWithNoClockStoredHasNoneAndStoresNothing() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(ClockStore(defaults: defaults).firstClock() == nil)
    #expect(ClockStore(defaults: defaults).all().isEmpty)
}

@Test func theFirstClockStoredIsTheOneALaunchDrives() throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClockStore(defaults: defaults)
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
    try store.replaceAll([desk, kitchen])

    #expect(store.firstClock() == desk)
    #expect(store.all() == [desk, kitchen])
}

// Sixteen through two instances, for the reason
// `concurrentRecordsThroughTwoInstancesAreNeverLostEither` gives: the lock
// guards the key, so a lock per instance loses records like no lock at all.
@Test func concurrentUpdatesThroughTwoStoresAreNeverLost() async throws {
    let suite = "clock-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = ClockStore(defaults: defaults)
    let second = ClockStore(defaults: defaults)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            let store = index.isMultiple(of: 2) ? first : second
            let clock = ClockRecord(name: "Clock \(index)", model: .awtrix3, address: "10.0.0.\(index)")
            group.addTask { store.update(clock) { _ in } }
        }
    }

    #expect(first.all().count == 16)
}
