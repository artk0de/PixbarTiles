import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// What the night light's settings offer, and where a choice goes.
@MainActor
@Suite struct NightLightTileBlockTests {
    private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.5")
    private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

    private func record(_ connectorId: String, on clock: ClockRecord, config: TileConfig? = nil) -> TileRecord {
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: connectorId),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 3_600), config: config
        )
    }

    @Test func eachSceneOffersASwitchPerMotionItDeclares() {
        #expect(NightLightTileBlock.motionKeys(of: .moon) == ["starTwinkle", "cloudMotion"])
        #expect(NightLightTileBlock.motionKeys(of: .fireplace) == ["flames", "sparks"])
        #expect(NightLightTileBlock.motionTitle("cloudMotion") == "Cloud motion")
        #expect(NightLightTileBlock.motionTitle("glowBreath") == "Glow breath")
    }

    @Test func theMorningIsTheFirstInOrderOrAnotherTileOnThisClock() {
        let light = record(NightLightKind.id, on: desk)
        let records = [record(WeatherKind.id, on: kitchen), light, record(WeatherKind.id, on: desk), record(ClaudeKind.id, on: desk)]
        let choices = NightLightTileBlock.morningChoices(of: light.key, among: records, name: { $0.key.connectorId })
        #expect(choices.map(\.title) == ["First in order", "weather", "claude"])
        #expect(choices.map(\.tileId) == [nil, records[2].key.tileId, records[3].key.tileId])
    }

    @Test func aChangedSettingIsTheTilesAtOnce() {
        let light = record(NightLightKind.id, on: desk)
        let model = testModel(
            connectors: [NightLightConnector(config: { NightLightTileConfig() }, canNameSleep: { false })],
            clocks: [desk], tiles: [light], sessions: [desk.id: SpyHost()]
        )
        model.openDetail(for: light.key)
        let settings = TileSettingsModel(model: model, debounce: 0)
        #expect(settings.setParameters(NightLightTileConfig(scene: .horizon, brightness: 2), kind: NightLightKind.self))
        #expect(model.storedTile(light.key)?.config?.nightLightConfig?.scene == .horizon)
        #expect(model.storedTile(light.key)?.config?.nightLightConfig?.brightness == 2)
    }
}
