import Foundation
import Testing
@testable import PixbarKit

@Suite struct AnimatedPageTests {
    private let dot = AnimationLayer(name: "d", pixels: [AnimationPixel(x: 1, y: 1, colour: RGB(r: 255, g: 72, b: 0))],
                                     multiplier: { f, n, _, _, _ in f * 2 < n ? 1000 : 400 })

    @Test func aSceneBecomesOneAnimatedImageFillingThePanel() throws {
        let scene = AnimatedScene(id: "t", frameMs: 100, cycleFrames: 4, layers: [dot])
        let delivery = try AnimatedPage.delivery(scene, speed: .normal, stilled: [], brightness: 5)
        let frame = try #require(delivery.scene.frames.first)
        let image = try #require(frame.image.first)
        #expect(delivery.scene.frames.count == 1)
        #expect(image.isAnimated && image.frameCount == 4)
        #expect(image.pixelSize.width == 52 && image.pixelSize.height == 16)
        #expect(image.position.x == 0 && image.position.y == 0)
    }

    @Test func overTheFrameCeilingItIsRefusedBeforeEncoding() {
        let scene = AnimatedScene(id: "t", frameMs: 100, cycleFrames: 241, layers: [dot])
        #expect(throws: AnimatedPage.CeilingExceeded.tooManyFrames(482)) {
            try AnimatedPage.delivery(scene, speed: .half, stilled: [], brightness: 5)
        }
    }

    @Test func theGifCarriesTheScenesDelayOnEveryFrame() throws {
        let scene = AnimatedScene(id: "t", frameMs: 150, cycleFrames: 2, layers: [dot])
        let data = try AnimatedPage.gif(scene, speed: .normal, stilled: [], brightness: 5)
        // Graphic Control Extension: 21 F9 04 <flags> <delay lo> <delay hi>
        let bytes = [UInt8](data)
        let delays = bytes.indices.dropLast(6).filter { bytes[$0] == 0x21 && bytes[$0 + 1] == 0xF9 }
            .map { Int(bytes[$0 + 4]) | Int(bytes[$0 + 5]) << 8 }
        #expect(delays == [15, 15])
    }
}
