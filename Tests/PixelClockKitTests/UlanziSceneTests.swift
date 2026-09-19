// Tests/PixelClockKitTests/UlanziSceneTests.swift
import Testing
@testable import PixelClockKit

@Suite struct UlanziSceneTests {
    // -- construction ------------------------------------------------------

    @Test func singleFrameSceneEncodesDbFromCanvas() throws {
        var canvas = PixelCanvas()
        canvas.fill(.white)
        let scene = UlanziScene(frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])])
        let json = try scene.jsonObject()
        let draw = json["draw"] as? [[String: Any]]
        #expect(draw?.count == 1)
        let bitmap = draw?[0]["db"] as? [Int]
        #expect(bitmap?.count == 2 + PixelCanvas.width * PixelCanvas.height)  // [w, h, w*h pixels]
        #expect(bitmap?[0] == PixelCanvas.width)
        #expect(bitmap?[1] == PixelCanvas.height)
    }

    @Test func sceneMustBeSingleFrame() {
        let frame = UlanziFrame(duration: 5, draw: [])
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [frame, frame]).jsonObject()
        }
    }

    // -- measured limits (research §4) --------------------------------------

    @Test func thirtyThreeDrawCommandsThrow() {
        let draw = Array(repeating: UlanziDraw.pixel(.zero, .white), count: 33)
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [UlanziFrame(duration: 5, draw: draw)]).jsonObject()
        }
    }

    @Test func thirtyTwoDrawCommandsPass() throws {
        let draw = Array(repeating: UlanziDraw.pixel(.zero, .white), count: 32)
        #expect((try UlanziScene(frames: [UlanziFrame(duration: 5, draw: draw)]).jsonObject()).isEmpty == false)
    }

    private let still = UlanziImage(
        base64: "a", isAnimated: false, frameCount: 1, pixelSize: (width: 64, height: 64)
    )
    private let gif = UlanziImage(
        base64: "a", isAnimated: true, frameCount: 10, pixelSize: (width: 64, height: 64)
    )

    @Test func seventhImageThrows() {
        #expect(throws: UlanziError.self) {
            try UlanziScene(
                frames: [UlanziFrame(duration: 5, image: Array(repeating: still, count: 7))]
            ).jsonObject()
        }
        // at the measured limit: six stills stand
        #expect(
            (try? UlanziScene(
                frames: [UlanziFrame(duration: 5, image: Array(repeating: still, count: 6))]
            ).jsonObject()) != nil
        )
    }

    @Test func fourthGifThrows() {
        let fiveImages = UlanziFrame(duration: 5, image: [still, still, still, gif, gif])
        // 3 stills + 2 gifs is inside every limit
        #expect((try? UlanziScene(frames: [fiveImages]).jsonObject()) != nil)
        // the fourth gif breaks the animated cap even though 6 images would fit
        #expect(throws: UlanziError.self) {
            try UlanziScene(
                frames: [UlanziFrame(duration: 5, image: [still, still, gif, gif, gif, gif])]
            ).jsonObject()
        }
    }

    @Test func gifOverTwoFiftySixSquareThrows() {
        let atLimit = UlanziImage(base64: "a", isAnimated: true, frameCount: 2, pixelSize: (256, 256))
        #expect((try? UlanziScene(frames: [UlanziFrame(duration: 5, image: [atLimit])]).jsonObject()) != nil)
        let over = UlanziImage(base64: "a", isAnimated: true, frameCount: 2, pixelSize: (257, 257))
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [UlanziFrame(duration: 5, image: [over])]).jsonObject()
        }
    }

    @Test func stillOverFiveTwelveSquareThrows() {
        let atLimit = UlanziImage(base64: "a", isAnimated: false, frameCount: 1, pixelSize: (512, 512))
        #expect((try? UlanziScene(frames: [UlanziFrame(duration: 5, image: [atLimit])]).jsonObject()) != nil)
        let over = UlanziImage(base64: "a", isAnimated: false, frameCount: 1, pixelSize: (513, 513))
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [UlanziFrame(duration: 5, image: [over])]).jsonObject()
        }
    }

    @Test func gifWithFiftyOneFramesThrows() {
        let atLimit = UlanziImage(base64: "a", isAnimated: true, frameCount: 50, pixelSize: (16, 16))
        #expect((try? UlanziScene(frames: [UlanziFrame(duration: 5, image: [atLimit])]).jsonObject()) != nil)
        let over = UlanziImage(base64: "a", isAnimated: true, frameCount: 51, pixelSize: (16, 16))
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [UlanziFrame(duration: 5, image: [over])]).jsonObject()
        }
    }

    @Test func base64OverSixtyKilobytesThrows() {
        let atLimit = UlanziImage(
            base64: String(repeating: "A", count: 60_000),
            isAnimated: true, frameCount: 50, pixelSize: (256, 256)
        )
        #expect((try? UlanziScene(frames: [UlanziFrame(duration: 5, image: [atLimit])]).jsonObject()) != nil)
        let over = UlanziImage(
            base64: String(repeating: "A", count: 60_001),
            isAnimated: true, frameCount: 50, pixelSize: (256, 256)
        )
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [UlanziFrame(duration: 5, image: [over])]).jsonObject()
        }
    }

    // -- text sanitization ---------------------------------------------------

    @Test func nonAsciiTextIsSanitizedToPrintableAscii() throws {
        let frame = UlanziFrame(duration: 5, text: [UlanziText(content: "héllo")])
        let json = try UlanziScene(frames: [frame]).jsonObject()
        // 'é' falls outside 0x20–0x7E; the encoder replaces it — assert the shape
        let text = json["text"] as? [String]
        #expect(text?[0].allSatisfy { $0.asciiValue != nil && (0x20...0x7E).contains($0.asciiValue!) } == true)
    }

    // -- idle scene (D4) ------------------------------------------------------

    @Test func idleSceneIsOneFrameWithAMarker() throws {
        let json = try UlanziScene.idle.jsonObject()
        #expect((json["draw"] as? [[String: Any]])?.count == 1)   // one db: the dim dot
    }
}
