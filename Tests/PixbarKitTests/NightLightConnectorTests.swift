import Foundation
import Testing
@testable import PixbarKit

/// The night light's connector: its reading is its scene, drawn by the engine.
@Suite struct NightLightConnectorTests {
    private func connector(_ config: NightLightTileConfig = NightLightTileConfig(), sleep: Bool = true) -> NightLightConnector {
        NightLightConnector(config: { config }, canNameSleep: { sleep })
    }

    @Test func itIsASilentAmbientSingleTile() {
        let subject = connector()
        #expect(subject.id == NightLightKind.id)
        #expect(subject.isAudible == false)
        #expect(subject.isAmbient)
        #expect(subject.instancing == .single)
        #expect(subject.ulanziFace != nil)
    }

    @Test func itKeepsSleepWhenTheMacCanNameItAndTheNightOtherwise() {
        #expect(connector(sleep: true).defaultPolicy == TileDefaults.nightLightSleep)
        #expect(connector(sleep: false).defaultPolicy == TileDefaults.nightLightHours)
    }

    @Test func aStoppedMotionTheSceneDoesNotOfferIsIgnored() async throws {
        let stale = NightLightTileConfig(scene: .fireplace, stilled: ["flames", "sparks"])
        let delivered = try await connector(stale).produceUlanzi()
        #expect(delivered == (try AnimatedPage.delivery(
            NightLightScene.fireplace.animatedScene, speed: .normal, stilled: [], brightness: 5
        )))
    }

    @Test func whatItDeliversIsTheScenesPageAtItsSettings() async throws {
        let config = NightLightTileConfig(scene: .moon, brightness: 3, speed: .double, stilled: ["cloudMotion"])
        let delivered = try await connector(config).produceUlanzi()
        let expected = try AnimatedPage.delivery(
            NightLightScene.moon.animatedScene, speed: .double, stilled: ["cloudMotion"], brightness: 3
        )
        #expect(delivered == expected)
        #expect(delivered != (try AnimatedPage.delivery(
            NightLightScene.moon.animatedScene, speed: .double, stilled: [], brightness: 3
        )))
    }
}
