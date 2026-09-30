import Foundation

/// Any animated scene as one TC002 page: every frame, full 52×16, in one
/// GIF with one global palette, placed at (0, 0) — the only form the panel
/// plays in step (`tc002-ticker-motion`).
public enum AnimatedPage {
    /// The panel's measured ceiling (2026-09-23): 478 frames / 135 240 B of
    /// base64 played on time.
    public static let maxFrames = 480
    public static let maxBase64Bytes = 136_000

    public enum CeilingExceeded: Error, Equatable {
        case tooManyFrames(Int)
        case tooLarge(Int)
    }

    public static func gif(_ scene: AnimatedScene, speed: AnimationSpeed, stilled: Set<String>, brightness: Int) throws -> Data {
        let n = scene.frameCount(speed: speed)
        guard n <= maxFrames else { throw CeilingExceeded.tooManyFrames(n) }
        let frames = (0..<n).map { scene.canvas(frame: $0, of: n, stilled: stilled, brightness: brightness) }
        let delay = TimeInterval(scene.frameMs) / 1000
        return try FullFrameGif.encode(frames: frames, delays: Array(repeating: delay, count: n))
    }

    public static func delivery(_ scene: AnimatedScene, speed: AnimationSpeed, stilled: Set<String>, brightness: Int) throws -> UlanziDelivery {
        let data = try gif(scene, speed: speed, stilled: stilled, brightness: brightness)
        let base64 = data.base64EncodedString()
        guard base64.utf8.count <= maxBase64Bytes else { throw CeilingExceeded.tooLarge(base64.utf8.count) }
        let n = scene.frameCount(speed: speed)
        let image = UlanziImage(base64: base64, isAnimated: n > 1, frameCount: n,
                                pixelSize: (width: AnimatedScene.width, height: AnimatedScene.height),
                                position: (x: 0, y: 0))
        return UlanziDelivery(scene: UlanziScene(frames: [UlanziFrame(duration: 5, image: [image])]))
    }
}
