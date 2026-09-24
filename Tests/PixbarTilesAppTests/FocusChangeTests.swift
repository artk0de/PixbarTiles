import PixbarKit
import Foundation
import Testing
@testable import PixbarTilesApp

// A Focus turning on or off, and the clock catching up with it.
//
// Nothing NOTIFIES this app that the user switched Focus — `INFocusStatusCenter`
// answers when asked and announces nothing — so the switch is noticed two ways:
// `FocusAssertionsWatcher` watches the file macOS writes the assertion to, and
// the reachability poll reconciles on its minute whatever that watcher missed
// (it needs Full Disk Access, and a machine without it has only the poll).
// Either way the reaction is this method. Without it, a tile whose policy
// depends on the Focus waits out its own cadence: up to five minutes
// to appear when work starts, and a whole lifetime to leave when Sleep does,
// which is a lit number on a clock beside a bed.

private let reconciledClock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")

private func claudeTile(on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: "claude"),
        policy: TilePolicyRecord(TileDefaults.codeUsage)
    )
}

@Test @MainActor func switchingIntoAFocusThatShowsItDeliversWithoutWaitingForTheBeat() async {
    let status = StubFocusStatus(
        access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")
    )
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: (status),
        clocks: [reconciledClock],
        tiles: [claudeTile(on: reconciledClock)]
    )

    // One turn to learn where the Focus started, so the next has something to
    // notice a change against.
    subject.reconcileTiles()
    status.nowIn(.mode("com.apple.focus.work"))
    subject.reconcileTiles()

    #expect(await waitUntil { host.calls.contains("run:claude") })
    #expect(!host.calls.contains("restore:claude"))
}

@Test @MainActor func switchingIntoAFocusThatHidesItTakesItOffTheClockAtOnce() async {
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: (status),
        clocks: [reconciledClock],
        tiles: [claudeTile(on: reconciledClock)]
    )

    subject.reconcileTiles()
    status.nowIn(.mode("com.apple.sleep.sleep-mode"))
    subject.reconcileTiles()

    // Retracted rather than merely left unrefreshed. Nothing on the clock takes
    // an app off for going stale until its lifetime expires, so "stop feeding
    // it" is fifteen minutes of a number that should already be gone.
    #expect(await waitUntil { host.calls.contains("restore:claude") })
    #expect(!host.calls.contains("run:claude"))
}

// A Focus that has not changed is not a reason to do anything.
//
// The poll turns once a minute for as long as the app is running. Re-pushing an
// unchanged app sixty times an hour would be sixty writes to the clock for a
// number that moves every five minutes, and re-retracting one that is already
// gone would be sixty more.
@Test @MainActor func aFocusThatStaysTheSameIsLeftAlone() async {
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: (status),
        clocks: [reconciledClock],
        tiles: [claudeTile(on: reconciledClock)]
    )

    for _ in 0..<4 { subject.reconcileTiles() }

    #expect(!host.calls.contains("run:claude"))
    #expect(!host.calls.contains("restore:claude"))
}

// The first reading is not a switch.
//
// `deliverWhatTheLaunchOwes` already hands the loop what a launch owes it, on
// the same poll this runs in. Counting the first reading as a transition would
// push the same app twice on the same turn — or, worse, retract the app the
// launch had just delivered.
@Test @MainActor func theFirstReadingIsNotTreatedAsASwitch() async {
    let asleep = StubFocusStatus(
        access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")
    )
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: (asleep),
        clocks: [reconciledClock],
        tiles: [claudeTile(on: reconciledClock)]
    )

    subject.reconcileTiles()

    #expect(!host.calls.contains("restore:claude"))
    #expect(!host.calls.contains("run:claude"))
}

// Working hours end without any Focus changing: the minute hand has to notice.
@Test @MainActor func aTileWhoseWorkingHoursEndIsTakenOffTheClock() async {
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let hour = HourBox(18)
    let host = SpyHost()
    var office = TileDefaults.codeUsage
    office.window = .active(HourWindow(startHour: 9, endHour: 19))
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .noFocus),
        now: { atHour(hour.value) },
        clocks: [clock],
        tiles: [TileRecord(key: TileKey(clockId: clock.id, connectorId: "claude"), policy: TilePolicyRecord(office))]
    )

    subject.reconcileTiles()
    hour.value = 19
    subject.reconcileTiles()

    #expect(await waitUntil { host.calls.contains("restore:claude") })
}

// An audible tile coming back waits for its beat. A Focus ending must not
// tell a joke on the spot.
@Test @MainActor func anAudibleTileBroughtBackWaitsForItsBeat() async {
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode"))
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "anecdotes")],
        host: host,
        focusStatus: status,
        now: { atHour(12) },
        clocks: [clock],
        tiles: [TileRecord(key: TileKey(clockId: clock.id, connectorId: "anecdotes"), policy: TilePolicyRecord(TileDefaults.anecdotes))]
    )

    subject.reconcileTiles()
    status.nowIn(.mode("com.apple.focus.work"))
    subject.reconcileTiles()

    #expect(await waitUntil({ host.calls.contains("run:anecdotes") }, limit: 0.1) == false)
}

@Test @MainActor func aPausedTileIsNeitherTakenOffNorBroughtBackByAFocus() async throws {
    let name = "paused-reconcile-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        defaults: defaults,
        focusStatus: status,
        now: { atHour(12) },
        clocks: [clock],
        tiles: [claudeTile(on: clock)]
    )
    // Then the user's hand pauses it, behind the model's back but through the
    // same store — the way B19's save will — AFTER the first reconciliation has
    // seen the tile running.
    let store = TileStore(defaults: defaults)

    subject.reconcileTiles()
    store.update(try #require(store.all().first)) { $0.policy.isPaused = true }
    status.nowIn(.mode("com.apple.sleep.sleep-mode"))
    subject.reconcileTiles()

    // A paused tile is out of the reconciliation entirely: a Focus switch on
    // either side of the pause takes nothing off and brings nothing back.
    // Waited on negatively but bounded — a retract that IS spawned loses the
    // race with an immediate read of an empty log.
    #expect(await waitUntil({ host.calls.contains("restore:claude") }, limit: 0.1) == false)
    #expect(host.calls.isEmpty)
}

private final class HourBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hour: Int
    init(_ hour: Int) { self.hour = hour }
    var value: Int {
        get { lock.withLock { hour } }
        set { lock.withLock { hour = newValue } }
    }
}
