// Tests/PixelClockTilesAppTests/UlanziWiringTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let okEnvelope = Data(#"{"code":200,"message":"ok"}"#.utf8)

private func drawnScene(colour: Pixel) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(colour)
    return UlanziScene(frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])])
}

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
    @Test @MainActor func liveRoutesTC002ClockRecordsToAUlanziSession() async throws {
        let (defaults, suite) = try openWiringDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try persist(
            ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9"),
            in: defaults
        )
        let transport = StubTransport(body: okEnvelope)

        let subject = AppModel.live(
            defaults: defaults,
            transport: transport,
            anecdoteStore: FileManager.default.temporaryDirectory
                .appendingPathComponent("ulanzi-\(UUID().uuidString).json")
        )

        let ulanzi = try #require(subject.ulanzi)
        let result = await ulanzi.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )

        #expect(result == .delivered)
        let posts = transport.requests.filter {
            $0.httpMethod == "POST" && $0.url?.path == "/api/custom"
        }
        #expect(posts.count == 1)
        #expect(posts.first?.url?.query == "name=pct-weather")
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

        #expect(subject.ulanzi == nil)
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

    @Test @MainActor func disabledConnectorKeepsItsPageAliveWithTheIdleFrame() async throws {
        let (defaults, suite) = try openWiringDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try persist(
            ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9"),
            in: defaults
        )
        let transport = StubTransport(body: okEnvelope)
        let subject = AppModel.live(
            defaults: defaults,
            transport: transport,
            anecdoteStore: FileManager.default.temporaryDirectory
                .appendingPathComponent("ulanzi-\(UUID().uuidString).json")
        )

        subject.setEnabled(false, for: StubConnector(id: "weather"))

        // D4: paused, never deleted — the page answers with the idle frame and
        // keeps its place in the knob cycle.
        #expect(await waitUntil {
            transport.requests.contains {
                $0.httpMethod == "POST" && $0.url?.query == "name=pct-weather"
            }
        })
        let idle = transport.requests.first {
            $0.httpMethod == "POST" && $0.url?.query == "name=pct-weather"
        }
        let body = try #require(idle?.httpBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        // The idle frame is the single dim dot: one filled circle.
        #expect((json["draw"] as? [[String: Any]])?.first?["dfc"] != nil)
    }
}
