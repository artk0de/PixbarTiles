import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

/// A queue file of its own per launch: `AnecdoteQueue.init` reads whatever
/// file it is handed, and a test has no business opening the user's.
private func scratchStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("records-\(UUID().uuidString).json")
}

// The phase's first claim. The first launch migrates; after that the record
// is what is read, so an address changed on the record is the one the next
// launch talks to.
@Test @MainActor func theLaunchReadsItsClockFromTheClockRecords() async throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    let clocks = ClockStore(defaults: defaults)
    let clock = try #require(clocks.all().first)
    clocks.update(clock) { $0.address = "10.0.0.7" }
    let transport = StubTransport(body: onlineStats)

    let relaunched = AppModel.live(
        defaults: defaults, transport: transport, anecdoteStore: scratchStore()
    )

    #expect(relaunched.deviceHost == "10.0.0.7")
    // And the device, which is what actually talks. The model is handed the
    // record and the device is built beside it, so a device built from anything
    // else would still leave the line above reporting the record's address.
    _ = await relaunched.monitor.refresh()
    #expect(transport.requests.map { $0.url?.host } == ["10.0.0.7"])
}

// Migrated, and then the list is gone — a hand-edited domain, nothing the app
// does. The launch still drives a clock, and stores it, so what the launch
// learns about it has somewhere to go.
@Test @MainActor func aLaunchWithNoClockStoredDrivesTheDefaultOneAndKeepsIt() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: ClockMigration.markerKey)

    let launched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(launched.deviceHost == AppModel.defaultDeviceHost)
    #expect(ClockStore(defaults: defaults).all().map(\.address) == [AppModel.defaultDeviceHost])
}
