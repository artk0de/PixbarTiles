// Tests/PixelClockTilesAppTests/UlanziClockSlotTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The TC002 clock's place in the schedule, end to end and on fixtures: the
// record's slot is the Ulanzi session, the health answers through /getBase,
// and a tile added on the clock delivers through the upsert path. The
// network is never touched — every request lands on the transport below.

/// Answers the three routes the TC002 firmware distinguishes — the bare
/// /getBase identity, the `customList` envelope, the `custom` envelope — and
/// the weather source beside them, recording everything.
final class UlanziPathTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var listed: [String] = []
    private var answering = true

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// What the clock currently lists as its custom apps — the sweep's input.
    func lists(_ names: [String]) { lock.withLock { listed = names } }

    /// The clock stops answering, as an unplugged one does.
    func stopAnswering() { lock.withLock { answering = false } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try lock.withLock { () throws -> Data in
            recorded.append(request)
            guard answering else { throw URLError(.cannotConnectToHost) }
            if request.url?.host == "api.open-meteo.com" { return liveSky }
            switch request.url?.path {
            case "/getBase":
                return Data(#"{"devSn":"sn-1","mac":"aa:bb","ip":"192.0.2.9"}"#.utf8)
            case "/api/customList":
                let names = listed.map { "\"\($0)\"" }.joined(separator: ",")
                return Data(
                    (#"{"code":200,"message":"ok","data":["# + names + #"]}"#).utf8
                )
            default:
                return Data(#"{"code":200,"message":"ok"}"#.utf8)
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:]
        )!
        return (body, response)
    }
}

/// The page writes that reached the clock, in order: the app's name and
/// whether the body was the empty delete or a page.
@MainActor
private func upserts(on transport: UlanziPathTransport) -> [(name: String, empty: Bool)] {
    transport.requests.compactMap { request in
        guard request.httpMethod == "POST", request.url?.path == "/api/custom",
            let query = request.url?.query, query.hasPrefix("name=")
        else { return nil }
        return (String(query.dropFirst(5)), (request.httpBody ?? Data()).isEmpty)
    }
}

/// The page write carrying drawn pixels — an upsert, not the empty delete.
@MainActor
/// A page counts as drawn when its upsert carries pixels — `draw[]` commands
/// or `image[]` GIFs (the weather face ships GIFs since 2026-09-23).
private func drewPage(named name: String, on transport: UlanziPathTransport) -> Bool {
    transport.requests.contains { request in
        guard request.httpMethod == "POST", request.url?.query == "name=\(name)",
              let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        else { return false }
        return body["draw"] != nil || body["image"] != nil
    }
}

/// A connector's single tile, as the schedule hands one to the slot. The
/// slot reads no clock off the key, so the clock is a placeholder.
private func slotTile(_ connectorId: String) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: UUID(uuid: UUID_NULL), connectorId: connectorId),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )
}

@MainActor
@Suite struct UlanziClockSlotTests {
    private let transport = UlanziPathTransport()
    private let suite = "ulanzi-slot-\(UUID().uuidString)"

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suite))
    }

    // MARK: the slot's own answers

    // Three of the six schedule answers are flat on purpose — nothing on a
    // TC002 restocks (no feed behind a page), nothing here takes an AWTRIX
    // delivery (the replay path is the anecdote's), and nothing device-wide
    // is ever borrowed. The lamps stay an AWTRIX surface: the TC002 has no
    // global indicators.
    @Test func theTC002SlotAnswersTheScheduleWithoutBorrowingOrLamps() async throws {
        let host = UlanziClockHost(
            session: UlanziClockSession(
                device: UlanziDevice(host: "192.0.2.9", transport: transport),
                custody: UlanziCustody(
                    device: UlanziDevice(host: "192.0.2.9", transport: transport),
                    record: UserDefaultsAppRecord(defaults: try defaults()),
                    clockId: "slot"
                )
            ),
            registry: ConnectorRegistry(),
            store: InMemorySettingsStore(),
            liveTiles: { [] }
        )
        #expect(host.indicators == nil)
        #expect(await host.maintain(tile: slotTile("weather")) == .skipped)
        #expect(await host.deliver(AwtrixDelivery(text: "hello")) == .skipped)
        #expect(await host.nextDelay(tile: slotTile("weather"), interval: 600) == 600)
        await host.restoreDeviceState(borrowedBy: nil)
        #expect(upserts(on: transport).isEmpty)
    }

    // A run sweeps once and then delivers through the upsert: the custody's
    // start-up pass reads the device's page list exactly once per session,
    // however many runs follow it.
    @Test func aRunSweepsOnceThenDeliversThroughTheUpsertPath() async throws {
        let record = UserDefaultsAppRecord(defaults: try defaults())
        // Both pages are recorded as ours — the live one and the stale one a
        // crash left behind — and the clock still lists both.
        record.save(["pct-weather", "pct-stale"], forClock: "slot")
        transport.lists(["pct-weather", "pct-stale"])
        let device = UlanziDevice(host: "192.0.2.9", transport: transport)
        let host = UlanziClockHost(
            session: UlanziClockSession(
                device: device,
                custody: UlanziCustody(
                    device: device, record: record, clockId: "slot"
                )
            ),
            registry: registryWithWeather(),
            store: InMemorySettingsStore(),
            liveTiles: { ["weather"] }
        )

        #expect(await host.runOnce(tile: slotTile("weather")) == .delivered)
        #expect(await host.runOnce(tile: slotTile("weather")) == .delivered)

        // One customList read for both runs, and the stale page's empty-body
        // delete (D10) beside the live page's upsert.
        let customLists = transport.requests.filter { $0.url?.path == "/api/customList" }
        #expect(customLists.count == 1)
        #expect(upserts(on: transport).contains { $0.name == "pct-stale" && $0.empty })
        #expect(drewPage(named: "pct-weather", on: transport))
    }

    // A connector with no TC002 face is a skip, not a failure — nothing
    // reaches the wire (D11's default, answered by the slot the catalogue
    // would never have placed the tile on).
    @Test func aConnectorWithNoTC002FaceIsASkip() async throws {
        let registry = ConnectorRegistry()
        registry.register(StubConnector())
        let host = UlanziClockHost(
            session: UlanziClockSession(
                device: UlanziDevice(host: "192.0.2.9", transport: transport),
                custody: UlanziCustody(
                    device: UlanziDevice(host: "192.0.2.9", transport: transport),
                    record: UserDefaultsAppRecord(defaults: try defaults()),
                    clockId: "slot"
                )
            ),
            registry: registry,
            store: InMemorySettingsStore(),
            liveTiles: { [] }
        )

        #expect(await host.runOnce(tile: slotTile("stub")) == .skipped)
        #expect(upserts(on: transport).isEmpty)
    }

    // An id nothing is registered under is a wiring mistake, said as such.
    @Test func anUnknownConnectorIdIsAFailureSaidInWords() async throws {
        let host = UlanziClockHost(
            session: UlanziClockSession(
                device: UlanziDevice(host: "192.0.2.9", transport: transport),
                custody: UlanziCustody(
                    device: UlanziDevice(host: "192.0.2.9", transport: transport),
                    record: UserDefaultsAppRecord(defaults: try defaults()),
                    clockId: "slot"
                )
            ),
            registry: ConnectorRegistry(),
            store: InMemorySettingsStore(),
            liveTiles: { [] }
        )

        if case let .failed(reason) = await host.runOnce(tile: slotTile("nowhere")) {
            #expect(reason.contains("nowhere"))
        } else {
            Issue.record("an unknown connector answered as anything but a failure")
        }
    }

    // MARK: the health

    // /getBase answering is the whole health: no battery line, no relocation,
    // and a word on the row — the same three words every clock's row uses.
    @Test func theTC002HealthAnswersThroughGetBaseAndSaysSo() async throws {
        let health = UlanziClockHealth(
            clockId: UUID(), name: "desk",
            device: UlanziDevice(host: "192.0.2.9", transport: transport),
            battery: nil
        )

        // Not asked yet: unknown, and not online — an answer nobody took is
        // not a disconnection.
        #expect(health.answering == .notAsked)
        #expect(health.isOnline == false)

        _ = await health.poll(at: Date())
        #expect(health.answering == .answering)
        #expect(health.isOnline)

        transport.stopAnswering()
        _ = await health.poll(at: Date())
        #expect(health.answering == .unreachable)
        #expect(health.isOnline == false)
    }

    // MARK: end to end, through the model's own cadences

    // The acceptance the user is about to run by hand: a stored TC002 record,
    // a transport answering /getBase, and the model left to its own loops.
    // The poll learns the clock is there and says so; the launch debt and the
    // schedule's own beat both deliver through the slot's upsert.
    @Test func aConfiguredTC002AnswersAndItsScheduleDeliversThroughTheUpsertPath() async throws {
        let defaults = try defaults()
        let desk = ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9")
        let schedule = Metronome()
        let polls = Metronome()
        let subject = testModel(
            connectors: [weatherConnector(over: transport)],
            transport: transport,
            defaults: defaults,
            sleep: schedule.sleep,
            pollSleep: polls.sleep,
            deviceHost: "192.0.2.9",
            clocks: [desk]
        )

        subject.start()
        polls.tick()
        #expect(await waitUntil { transport.requests.contains { $0.url?.path == "/getBase" } })
        #expect(subject.statusLine(of: desk) == "Connected")
        #expect(
            await waitUntil {
                upserts(on: transport).contains { $0.name == "pct-weather" && $0.empty == false }
            }
        )

        // The cadence itself runs the slot — the schedule the stopgap refused
        // to arm for a TC002 record.
        schedule.tick()
        #expect(await waitUntil { upserts(on: transport).count >= 2 })

        // And the quit is the custody's teardown: every owned page gets its
        // empty-body delete (D4).
        await subject.teardown()
        #expect(await waitUntil {
            upserts(on: transport).contains { $0.name == "pct-weather" && $0.empty }
        })
    }

    // A tile added on the clock delivers through the upsert path — the Add
    // tile menu's placement turns into pixels on the TC002, not a silent
    // store row.
    @Test func aTileAddedOnTheTC002ClockDeliversThroughTheUpsertPath() async throws {
        let defaults = try defaults()
        let desk = ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9")
        let subject = testModel(
            connectors: [weatherConnector(over: transport)],
            transport: transport,
            defaults: defaults,
            deviceHost: "192.0.2.9",
            clocks: [desk],
            tiles: []
        )

        let key = TileKey(clockId: desk.id, connectorId: "weather")
        #expect(subject.addTile("weather", to: desk.id) == .saved)
        subject.runNow(key)

        #expect(await waitUntil { drewPage(named: "pct-weather", on: transport) })
    }

    // A TC002 that stops answering is said to have stopped, and its tiles'
    // schedules say what is holding them — the same hold an AWTRIX outage
    // writes, from the TC002's own health.
    @Test func aTC002ThatStopsAnsweringHoldsItsScheduleAndSaysSo() async throws {
        let defaults = try defaults()
        let desk = ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9")
        let polls = Metronome()
        let subject = testModel(
            connectors: [weatherConnector(over: transport)],
            transport: transport,
            defaults: defaults,
            sleep: Metronome().sleep,
            pollSleep: polls.sleep,
            deviceHost: "192.0.2.9",
            clocks: [desk]
        )
        let key = TileKey(clockId: desk.id, connectorId: "weather")

        subject.start()
        polls.tick()
        #expect(await waitUntil { transport.requests.contains { $0.url?.path == "/getBase" } })

        transport.stopAnswering()
        polls.tick()
        #expect(await waitUntil { subject.statusLine(of: desk) == "Disconnected" })
        #expect(
            await waitUntil {
                subject.tileNextRun[key] == NextRun.held(AppModel.deviceUnreachable)
            }
        )
        await subject.teardown()
    }

    // MARK: fixtures

    /// A registry holding the fixture weather connector — the one connector
    /// in this target with both a reading and a TC002 face.
    private func registryWithWeather() -> ConnectorRegistry {
        let registry = ConnectorRegistry()
        registry.register(weatherConnector(over: transport))
        return registry
    }
}
