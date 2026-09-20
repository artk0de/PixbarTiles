import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The Clocks section's four actions: add by address, add from discovery,
// rename, remove. The dual probe decides the model; the store is the record;
// removal is the one action that takes pages back.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")

private let emptyIdentity = UlanziIdentity(
    serial: nil, mac: nil, ip: nil, mcuVersion: nil, appVersion: nil
)

// The probe decides, and status codes have no part in it: the model stored is
// whichever body decoded.
@Test @MainActor func addingByAddressTakesTheModelTheProbeDecodes() async throws {
    let defaults = try #require(UserDefaults(suiteName: "clock-action-\(UUID().uuidString)"))

    let ulanzi = testModel(
        defaults: defaults,
        clocks: [desk],
        tiles: [],
        probe: { _ in .ulanzi(emptyIdentity) }
    )
    #expect(await ulanzi.addClock(address: "10.0.0.9") == .added)
    #expect(ulanzi.clocks.last?.model == .ulanziTC002)
    #expect(ulanzi.clocks.last?.address == "10.0.0.9")
    #expect(ClockStore(defaults: defaults).all().last?.model == .ulanziTC002)

    let other = testModel(
        defaults: defaults,
        clocks: [desk],
        tiles: [],
        probe: { _ in .otherDevice }
    )
    #expect(await other.addClock(address: "10.0.0.9") == .added)
    #expect(other.clocks.last?.model == .awtrix3)
}

// Nothing decoded at the address, so nothing is stored: the refusal is the
// outcome, not a record for a clock that never answered.
@Test @MainActor func anAddressNothingDecodedAtIsRefused() async throws {
    let defaults = try #require(UserDefaults(suiteName: "clock-action-\(UUID().uuidString)"))
    let subject = testModel(
        defaults: defaults,
        clocks: [desk],
        tiles: [],
        probe: { _ in .undetermined }
    )

    #expect(await subject.addClock(address: "10.0.0.9") != .added)
    #expect(subject.clocks == [desk])
    #expect(ClockStore(defaults: defaults).all() == [desk])
}

// An address already configured is refused rather than stored twice.
@Test @MainActor func anAddressAlreadyConfiguredIsRefused() async throws {
    let subject = testModel(
        clocks: [desk],
        tiles: [],
        probe: { _ in .otherDevice }
    )

    #expect(await subject.addClock(address: desk.address) != .added)
    #expect(subject.clocks == [desk])
}

// Discovery's list carried name, model and address; the record is what it
// said, not a second probe over a clock that already announced itself.
@Test @MainActor func addingFromDiscoveryStoresWhatTheListCarried() async throws {
    let subject = testModel(clocks: [desk], tiles: [])

    #expect(
        subject.addClock(from: DiscoveredClock(name: "Kitchen", model: "TC002", address: "10.0.0.6"))
            == .added
    )
    #expect(subject.clocks.last?.name == "Kitchen")
    #expect(subject.clocks.last?.model == .ulanziTC002)

    #expect(
        subject.addClock(from: DiscoveredClock(name: "awtrix_a07f9c", model: "AWTRIX", address: "10.0.0.7"))
            == .added
    )
    #expect(subject.clocks.last?.model == .awtrix3)
}

// A rename goes through the store and touches nothing else: no session call,
// no schedule moved — the clock, its session and its tiles are all the same.
@Test @MainActor func renamingWritesThroughTheStoreAndTouchesNothingElse() async throws {
    let host = SpyHost()
    let defaults = try #require(UserDefaults(suiteName: "clock-action-\(UUID().uuidString)"))
    let subject = testModel(
        defaults: defaults,
        clocks: [desk, kitchen],
        tiles: [],
        sessions: [desk.id: SpyHost(), kitchen.id: host]
    )

    subject.renameClock(kitchen.id, to: "Loft")

    #expect(subject.clocks.first { $0.id == kitchen.id }?.name == "Loft")
    #expect(ClockStore(defaults: defaults).all().first { $0.id == kitchen.id }?.name == "Loft")
    #expect(host.calls.isEmpty)
}

// Removal takes every tile off the clock through its session's teardown and
// drops the record — and nothing of the clock that stays is disturbed.
@Test @MainActor func removingATakesEveryTileOffThroughTheSessionsTeardown() async throws {
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let defaults = try #require(UserDefaults(suiteName: "clock-action-\(UUID().uuidString)"))
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        defaults: defaults,
        clocks: [desk, kitchen],
        tiles: [
            TileRecord(
                key: TileKey(clockId: desk.id, connectorId: "claude"),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
            ),
            TileRecord(
                key: TileKey(clockId: kitchen.id, connectorId: "claude"),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
            ),
        ],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )
    subject.selectedClockId = kitchen.id

    subject.removeClock(kitchen.id)

    #expect(await waitUntil { inKitchen.calls.contains("restore:all") })
    #expect(onDesk.calls.isEmpty)
    #expect(subject.storedPolicy(of: TileKey(clockId: kitchen.id, connectorId: "claude")) == nil)
    #expect(subject.storedPolicy(of: TileKey(clockId: desk.id, connectorId: "claude")) != nil)
    #expect(subject.clocks == [desk])
    #expect(ClockStore(defaults: defaults).all() == [desk])
    // The selection never dangles on the clock that is gone.
    #expect(subject.selectedClockId == desk.id)
}

// The TC002 branch of removal: the session's teardown is the custody
// releaseAll — every owned page gets the empty-body delete.
@Test @MainActor func removingATC002ReleasesItsPagesThroughItsSession() async throws {
    let suite = "clock-action-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let tc002 = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "192.0.2.9")
    defaults.set(true, forKey: ClockMigration.markerKey)
    defaults.set(try JSONEncoder().encode([tc002]), forKey: ClockStore.key)
    let transport = StubTransport(body: Data(#"{"code":200,"message":"ok"}"#.utf8))
    let subject = AppModel.live(
        defaults: defaults,
        transport: transport,
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("clock-action-\(UUID().uuidString).json")
    )
    let ulanzi = try #require(subject.ulanzi)
    var canvas = PixelCanvas()
    canvas.fill(.white)
    _ = await ulanzi.deliver(
        UlanziDelivery(scene: UlanziScene(frames: [
            UlanziFrame(duration: 5, draw: [canvas.drawCommands()])
        ])),
        toTile: "weather"
    )

    subject.removeClock(tc002.id)

    #expect(await waitUntil {
        transport.requests.contains { request in
            request.httpMethod == "POST"
                && request.url?.query == "name=pct-weather"
                && (request.httpBody ?? Data()).isEmpty
        }
    })
    #expect(subject.clocks.isEmpty)
}
