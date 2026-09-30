import Foundation
import Testing
@testable import PixbarKit

@Suite struct NightLightScenesTests {
    @Test func theOracleHoldsEverySceneTheTileOffers() throws {
        let oracle = try AnimationOracle.load()
        #expect(Set(oracle.scenes.keys) == Set(NightLightScene.allCases.map(\.rawValue)))
    }

    @Test func everySceneKeepsItsLoopAndItsMotionSwitches() throws {
        let oracle = try AnimationOracle.load()
        for scene in NightLightScene.allCases {
            let recorded = try #require(oracle.scenes[scene.rawValue])
            let animated = scene.animatedScene
            #expect(animated.frameMs == recorded.frameMs, "\(scene)")
            #expect(animated.cycleFrames == recorded.cycleFrames, "\(scene)")
            let keys = animated.layers.compactMap(\.key).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            #expect(keys == recorded.toggles, "\(scene)")
        }
    }
}

extension NightLightScenesTests {
    @Test(arguments: NightLightScene.allCases)
    func theDefaultLoopIsTheMockupPixelForPixel(scene: NightLightScene) throws {
        let recorded = try #require(try AnimationOracle.load().scenes[scene.rawValue])
        let expected = try recorded.frames()
        let animated = scene.animatedScene
        let n = animated.frameCount(speed: .normal)
        #expect(n == expected.count)
        for f in 0..<min(n, expected.count) {
            let got = animated.canvas(frame: f, of: n, stilled: [], brightness: 5)
            for i in 0..<832 {
                let want = expected[f][i].map { Pixel(red: UInt8($0.r), green: UInt8($0.g), blue: UInt8($0.b)) } ?? .black
                if got[i % 52, i / 52] != want {
                    Issue.record("\(scene) frame \(f) (\(i % 52),\(i / 52)): \(got[i % 52, i / 52]) ≠ \(want)")
                    return
                }
            }
        }
    }

    @Test(arguments: NightLightScene.allCases)
    func everyVariantMatchesItsRecordedDigest(scene: NightLightScene) throws {
        let animated = scene.animatedScene
        for variant in try AnimationOracle.load().variants where variant.scene == scene.rawValue {
            let speed = try #require(AnimationSpeed(fraction: variant.speed))
            let n = animated.frameCount(speed: speed)
            #expect(n == variant.frames, "\(scene) \(variant.speed)")
            let frames = (0..<n).map { animated.canvas(frame: $0, of: n, stilled: Set(variant.stilled), brightness: variant.brightness) }
            #expect(AnimationOracle.fnv(frames) == variant.fnv,
                    "\(scene) speed \(variant.speed) stilled \(variant.stilled) brightness \(variant.brightness)")
        }
    }

    @Test(arguments: NightLightScene.allCases)
    func everyLoopIsSeamlessAndFitsThePanelAtEverySpeed(scene: NightLightScene) throws {
        let animated = scene.animatedScene
        for speed in [AnimationSpeed.half, .normal, .double] {
            let n = animated.frameCount(speed: speed)
            #expect(animated.render(frame: n, of: n, stilled: []) == animated.render(frame: 0, of: n, stilled: []))
            #expect(throws: Never.self) { try AnimatedPage.delivery(animated, speed: speed, stilled: [], brightness: 5) }
        }
    }
}
