import Testing
@testable import PixbarKit

@Suite struct AnimatedSceneTests {
    private func scene(_ layers: [AnimationLayer], tint: AnimatedScene.Tint? = nil) -> AnimatedScene {
        AnimatedScene(id: "t", frameMs: 100, cycleFrames: 10, layers: layers, tint: tint)
    }

    @Test func aLaterLayerDrawsOverAnEarlierOneAndXWraps() {
        let a = AnimationLayer(name: "a", pixels: [AnimationPixel(x: 0, y: 0, colour: RGB(r: 100, g: 0, b: 0))])
        let b = AnimationLayer(name: "b", pixels: [AnimationPixel(x: 51, y: 0, colour: RGB(r: 0, g: 0, b: 50))],
                               offset: { _, _ in (dx: 1, dy: 0) })
        let grid = scene([a, b]).render(frame: 0, of: 10, stilled: [])
        #expect(grid[0] == RGB(r: 0, g: 0, b: 50))
    }

    /// A stilled layer holds its first frame: a layer whose multiplier cuts
    /// its silhouette (the fireplace's flames) drawn at full base lit every
    /// cell it could ever reach — a solid block on the panel.
    @Test func aStilledLayerHoldsItsFirstFrame() {
        let moving = AnimationLayer(name: "m", pixels: [AnimationPixel(x: 3, y: 3, colour: RGB(r: 200, g: 0, b: 0))],
                                    multiplier: { frame, _, _, _, _ in frame == 0 ? 500 : 0 },
                                    offset: { frame, _ in (dx: frame, dy: 0) },
                                    key: "k")
        let still = scene([moving]).render(frame: 4, of: 10, stilled: ["k"])
        #expect(still == scene([moving]).render(frame: 0, of: 10, stilled: []))
        #expect(still[3 * 52 + 3] == RGB(r: 100, g: 0, b: 0))
        #expect(scene([moving]).render(frame: 4, of: 10, stilled: []).allSatisfy { $0 == nil })
    }

    @Test func aStoppedFireflyStaysPutAndKeepsGlowing() {
        let flies = NightLightScene.fireflies.animatedScene
        let n = flies.cycleFrames
        let frames = (0..<n).map { flies.render(frame: $0, of: n, stilled: ["flyMotion"]) }
        // Still glowing: the frames differ.
        #expect(Set(frames.map { $0.map { $0 == nil } }).count > 1)
        // Staying put: every lit cell lies where the flies stood at frame 0.
        var home: Set<Int> = []
        for layer in flies.layers {
            let (dx, dy) = layer.offset(0, n)
            for p in layer.pixels where (0..<16).contains(p.y + dy) {
                home.insert((p.y + dy) * 52 + IntMath.floorMod(p.x + dx, 52))
            }
        }
        #expect(frames.allSatisfy { f in f.indices.allSatisfy { f[$0] == nil || home.contains($0) } })
    }

    @Test func aStilledFireplaceIsItsFirstFrameNotABlock() {
        let fire = NightLightScene.fireplace.animatedScene
        let n = fire.cycleFrames
        #expect(fire.render(frame: 37, of: n, stilled: ["flames", "sparks"]) == fire.render(frame: 0, of: n, stilled: []))
    }

    @Test func aTintAnimatesRedOnlyAndHoldsGreenWhereTheRedCarriesIt() {
        let p = AnimationLayer(name: "p", pixels: [AnimationPixel(x: 0, y: 0, colour: RGB(r: 200, g: 144, b: 0))],
                               multiplier: { f, _, _, _, _ in f == 0 ? 1000 : 500 })
        let s = scene([p], tint: { RGB(r: PanelLevels.red($0), g: 0, b: 0) })
        #expect(s.render(frame: 0, of: 2, stilled: [])[0] == RGB(r: 255, g: 144, b: 0))
        #expect(s.render(frame: 1, of: 2, stilled: [])[0] == RGB(r: 176, g: 100, b: 0))   // red 100 → 176, 144 not carried
    }

    @Test func speedPlaysTheSameCyclesInMoreOrFewerFrames() {
        let s = scene([])
        #expect(s.frameCount(speed: .half) == 20)
        #expect(s.frameCount(speed: .normal) == 10)
        #expect(s.frameCount(speed: .double) == 5)
    }

    @Test func brightnessScalesEveryChannelAndDropsWhatGoesDark() {
        let p = AnimationLayer(name: "p", pixels: [AnimationPixel(x: 0, y: 0, colour: RGB(r: 40, g: 0, b: 0)),
                                                   AnimationPixel(x: 1, y: 0, colour: RGB(r: 1, g: 0, b: 0))])
        let canvas = scene([p]).canvas(frame: 0, of: 10, stilled: [], brightness: 1)
        #expect(canvas[0, 0] == Pixel(red: 8, green: 0, blue: 0))    // (40·1 + 2) / 5
        #expect(canvas[1, 0] == .black)                               // (1·1 + 2) / 5 = 0
    }
}
