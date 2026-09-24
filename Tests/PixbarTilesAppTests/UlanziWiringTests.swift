// Tests/PixbarTilesAppTests/UlanziWiringTests.swift
import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

private let okEnvelope = Data(#"{"code":200,"message":"ok"}"#.utf8)

/// Writes one clock record where `live()` will find it, in an installation
/// whose migration has already run — the shape a manual TC002 record arrives
/// in: the AWTRIX legacy keys are old history, the record is the present.
@MainActor
private func persist(_ clock: ClockRecord, in defaults: UserDefaults) throws {
    defaults.set(true, forKey: ClockMigration.markerKey)
    defaults.set(try JSONEncoder().encode([clock]), forKey: ClockStore.key)
}

private func openWiringDefaults() throws -> (UserDefaults, String) {
    let suite = "ulanzi-wiring-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

@Suite struct UlanziWiringTests {
    // The TC002 record's slot in the schedule is the Ulanzi session, and the
    // pause event reaches the wire through it: the idle-frame upsert that
    // keeps the page in the knob cycle (D4). Under the stopgap this POST
    // never happened — the slot answered every call with a skip, so a
    // configured TC002 was never probed and never pushed anything.
    @Test @MainActor func theTC002RecordDrivesTheUlanziSessionThroughItsScheduleSlot() async throws {
        let (defaults, suite) = try openWiringDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tc002 = ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9")
        try persist(tc002, in: defaults)
        let transport = StubTransport(body: okEnvelope)

        let subject = AppModel.live(
            defaults: defaults,
            transport: transport,
            anecdoteStore: FileManager.default.temporaryDirectory
                .appendingPathComponent("ulanzi-\(UUID().uuidString).json")
        )

        subject.setPaused(true, tile: TileKey(clockId: tc002.id, connectorId: "weather"))

        #expect(await waitUntil {
            transport.requests.contains { request in
                request.httpMethod == "POST"
                    && request.url?.query == "name=pct-weather"
                    && (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                        as? [String: Any])?["draw"] != nil
            }
        })
        // The idle frame is the single dim dot: one filled circle.
        let idle = transport.requests.last {
            $0.httpMethod == "POST" && $0.url?.query == "name=pct-weather"
        }
        let body = try #require(idle?.httpBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect((json["draw"] as? [[String: Any]])?.first?["dfc"] != nil)
    }

    @Test @MainActor func liveKeepsAwtrixRoutingUntouched() async throws {
        let (defaults, suite) = try openWiringDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try persist(
            ClockRecord(name: "desk", model: .awtrix3, address: "192.0.2.9"),
            in: defaults
        )
        let transport = StubTransport(
            body: Data(#"{"power":true,"brightness":30,"uid":"u1"}"#.utf8)
        )

        let subject = AppModel.live(
            defaults: defaults,
            transport: transport,
            anecdoteStore: FileManager.default.temporaryDirectory
                .appendingPathComponent("ulanzi-\(UUID().uuidString).json")
        )

        // The phase-2 session is what the lamps go through — the same shape as
        // before this phase, and the proof that the AWTRIX route survived.
        subject.refreshLamps()
        #expect(await waitUntil {
            Set(
                transport.requests.compactMap(\.url?.path)
                    .filter { $0.hasPrefix("/api/indicator") }
            ) == ["/api/indicator1", "/api/indicator3"]
        })
    }
}
