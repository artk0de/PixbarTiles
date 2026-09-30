import Foundation
import Testing
@testable import PixbarKit

/// The night light's own settings, stored under its kind.
@Suite struct NightLightTileConfigTests {
    private func json(_ config: TileConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(config), as: UTF8.self)
    }

    @Test func theDefaultsWriteNothing() throws {
        let config = TileConfig(NightLightTileConfig(), kind: NightLightKind.self)
        #expect(try json(config) == #"{"nightlight":{}}"#)
        let back = try JSONDecoder().decode(TileConfig.self, from: Data(#"{"nightlight":{}}"#.utf8))
        #expect(back.value(as: NightLightTileConfig.self) == NightLightTileConfig())
    }

    @Test func everySettingSurvivesARoundTrip() throws {
        let edited = NightLightTileConfig(
            scene: .moon, brightness: 2, speed: .double, stilled: ["cloudMotion"],
            autoShow: false, morningTileId: "weather"
        )
        let config = TileConfig(edited, kind: NightLightKind.self)
        let back = try JSONDecoder().decode(TileConfig.self, from: JSONEncoder().encode(config))
        #expect(back == config)
        #expect(back.nightLightConfig == edited)
    }

    @Test func theSpeedsAreTheEnginesSpeeds() {
        #expect(NightLightSpeed.half.animationSpeed == .half)
        #expect(NightLightSpeed.normal.animationSpeed == .normal)
        #expect(NightLightSpeed.double.animationSpeed == .double)
    }

    @Test func theTwoDefaultPoliciesAreSleepOrTheNight() {
        #expect(TileDefaults.nightLightSleep.runs(in: .sleep, atHour: 14))
        #expect(TileDefaults.nightLightSleep.runs(in: .noFocus, atHour: 23) == false)
        #expect(TileDefaults.nightLightSleep.runs(in: .unknown, atHour: 23) == false)
        #expect(TileDefaults.nightLightHours.runs(in: .work, atHour: 23))
        #expect(TileDefaults.nightLightHours.runs(in: .noFocus, atHour: 6) == false)
    }

    @Test func aKindNarrowsTheModelsOfALiveConnector() {
        let both = FacedConnector(id: NightLightKind.id)
        #expect(TileCandidate(both).models == [.ulanziTC002])
        let unknown = FacedConnector(id: "nope")
        #expect(TileCandidate(unknown).models == [.awtrix3, .ulanziTC002])
    }
}

/// A connector with both faces, under any id.
private struct FacedConnector: Connector {
    let id: String
    var displayName: String { id }
    var defaultInterval: TimeInterval { 60 }
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
    var ulanziFace: UlanziFace<Int>? { UlanziFace { _ in UlanziDelivery(scene: UlanziScene(frames: [])) } }
}
