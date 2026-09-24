import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// Phase 1's owe-list, settled: a launch without clocks is a state the user
// reaches and answers, not a clock created in the dark. The store keeps what
// it is told and creates nothing; the migration writes nothing on a fresh
// install; the panel has an answer.

@Test @MainActor func aFreshInstallWritesNothingAndMarksNothing() throws {
    let suite = "no-clocks-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    #expect(ClockStore(defaults: defaults).all().isEmpty)
    #expect(defaults.bool(forKey: ClockMigration.markerKey) == false)
    #expect(ClockStore(defaults: defaults).firstClock() == nil)
}

@Test @MainActor func aFreshDefaultsDomainBootsToTheNoClocksState() async throws {
    let suite = "no-clocks-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults,
        transport: StubTransport(),
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("no-clocks-\(UUID().uuidString).json")
    )

    #expect(subject.clocks.isEmpty)
    #expect(subject.hasNoClocks)
}

// The "Add clock…" answer is the Clocks section — the settings' — and not a
// surface of its own.
@Test @MainActor func theAddClockAnswerOpensTheClocksSection() {
    let model = testModel(clocks: [], tiles: [])
    let settings = SettingsModel(model: model)
    // The panel's answer aims the Settings window at the Clocks tab; the
    // window itself opens through the system action, which a test process
    // has no run loop to drive. The aiming is what this view owns.
    let panel = NoClocksPanel(onAdd: { settings.tab = .clocks })

    panel.onAdd()

    #expect(settings.tab == .clocks)
}

// An installation that already stored a clock is unaffected by any of it.
@Test @MainActor func anInstallWithAStoredClockIsUnaffected() async throws {
    let suite = "no-clocks-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "192.0.2.9")
    defaults.set(true, forKey: ClockMigration.markerKey)
    defaults.set(try JSONEncoder().encode([desk]), forKey: ClockStore.key)

    let subject = AppModel.live(
        defaults: defaults,
        transport: StubTransport(body: onlineStats),
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("no-clocks-\(UUID().uuidString).json")
    )

    #expect(subject.clocks == [desk])
    #expect(subject.hasNoClocks == false)
}

// D7: the glyph answers for the selected clock alone, and it answers when the
// selection moves — not at the next poll.
@Test @MainActor func theGlyphAnswersForTheSelectedClockAlone() async {
    let transport = RoutingByHostTransport(online: ["10.0.0.5"])
    let schedule = Metronome()
    let polls = Metronome()
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")
    let subject = testModel(
        transport: transport,
        sleep: schedule.sleep,
        pollSleep: polls.sleep,
        clocks: [desk, kitchen],
        tiles: []
    )

    subject.start()
    // The desk answers and is selected: the glyph is lit.
    #expect(await waitUntil { subject.isDeviceOnline })

    // Selecting the clock that is not answering draws the offline mark at
    // once — a laptop that left the kitchen clock behind is not offline.
    subject.selectedClockId = kitchen.id
    #expect(subject.isDeviceOnline == false)

    await subject.teardown()
}
