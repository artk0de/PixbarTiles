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
        // [x, y, w, h, [w*h pixels]] — position first, pixels NESTED. The flat
        // [w, h, p0, …] spelling is accepted with 200 and draws a black page
        // (measured on the TC002, appVer 1.1.1, 2026-09-23).
        let bitmap = try #require(draw?[0]["db"] as? [Any])
        #expect(bitmap.count == 5)
        #expect(bitmap[0] as? Int == 0)
        #expect(bitmap[1] as? Int == 0)
        #expect(bitmap[2] as? Int == PixelCanvas.width)
        #expect(bitmap[3] as? Int == PixelCanvas.height)
        let pixels = try #require(bitmap[4] as? [Int])
        #expect(pixels.count == PixelCanvas.width * PixelCanvas.height)
        #expect(pixels.allSatisfy { $0 == 0xFF_FF_FF })
    }

    @Test func positionedBitmapEncodesItsPositionFirst() throws {
        let draw = UlanziDraw.bitmap(
            width: 2, height: 1, pixels: [0x12_34_56, 0xAB_CD_EF], at: PixelPoint(x: 7, y: 3)
        )
        let json = try UlanziScene(frames: [UlanziFrame(duration: 5, draw: [draw])]).jsonObject()
        let bitmap = try #require((json["draw"] as? [[String: Any]])?[0]["db"] as? [Any])
        #expect(bitmap[0] as? Int == 7)
        #expect(bitmap[1] as? Int == 3)
        #expect(bitmap[2] as? Int == 2)
        #expect(bitmap[3] as? Int == 1)
        #expect(bitmap[4] as? [Int] == [0x12_34_56, 0xAB_CD_EF])
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

    // -- the measured envelope (live TC002, 2026-09-21) -----------------------

    // A string in text[] renders nothing on appVer 1.1.1 — the page goes
    // black. The element is an object, with the doc's defaults: 10 px, white,
    // placed by align/valign until x/y say otherwise.
    @Test func textElementsAreObjectsWithTheDocDefaults() throws {
        let json = try UlanziScene(
            frames: [UlanziFrame(duration: 5, text: [UlanziText(content: "hi")])]
        ).jsonObject()
        let text = json["text"] as? [[String: Any]]
        #expect(text?.count == 1)
        #expect(text?[0]["content"] as? String == "hi")
        #expect(text?[0]["fontHeight"] as? Int == 10)
        #expect(text?[0]["x"] as? Int == UlanziText.autoPosition)
        #expect(text?[0]["y"] as? Int == UlanziText.autoPosition)
        #expect(text?[0]["color"] as? String == "#FFFFFF")
    }

    @Test func textPlacementSizeAndColourCarryThrough() throws {
        let text = UlanziText(
            content: "42%", fontHeight: .small, x: 0, y: 1, color: UlanziColour(value: 0xD97757)
        )
        let json = try UlanziScene(frames: [UlanziFrame(duration: 5, text: [text])]).jsonObject()
        let element = (json["text"] as? [[String: Any]])?[0]
        #expect(element?["fontHeight"] as? Int == 5)
        #expect(element?["x"] as? Int == 0)
        #expect(element?["y"] as? Int == 1)
        #expect(element?["color"] as? String == "#D97757")
    }

    // The image element is an object too: the payload rides a GIF data URL
    // and carries its own top-left corner. Bare base64 — string or data URL —
    // rendered nothing on the same firmware.
    @Test func imageElementsAreDataUrlObjectsAtTheOrigin() throws {
        let json = try UlanziScene(
            frames: [UlanziFrame(duration: 5, image: [still])]
        ).jsonObject()
        let images = json["image"] as? [[String: Any]]
        #expect(images?.count == 1)
        #expect(images?[0]["data"] as? String == "data:image/gif;base64,a")
        #expect(images?[0]["position"] as? [Int] == [0, 0])
    }

    @Test func anImageElementCarriesItsOwnCorner() throws {
        let icon = UlanziImage(
            base64: "a", isAnimated: false, frameCount: 1,
            pixelSize: (16, 16), position: (12, 4)
        )
        let json = try UlanziScene(frames: [UlanziFrame(duration: 5, image: [icon])]).jsonObject()
        let images = json["image"] as? [[String: Any]]
        #expect(images?[0]["position"] as? [Int] == [12, 4])
    }

    // A face may hand over a GIF that already carries its own timing — two
    // frames with a DelayTime each, alternating on the panel by itself. The
    // kit does not parse the bytes: it validates the declared counts and
    // ships the payload through to the wire untouched.
    @Test func aPreTimedGifShipsThroughToTheWireUnchanged() throws {
        let timedGif = UlanziImage(
            base64: "R0lGODlh", isAnimated: true, frameCount: 2, pixelSize: (52, 16)
        )
        let json = try UlanziScene(
            frames: [UlanziFrame(duration: 5, image: [timedGif])]
        ).jsonObject()
        let images = json["image"] as? [[String: Any]]
        #expect(images?[0]["data"] as? String == "data:image/gif;base64,R0lGODlh")
        #expect(images?[0]["position"] as? [Int] == [0, 0])
    }

    // -- text sanitization ---------------------------------------------------

    @Test func nonAsciiTextIsSanitizedToPrintableAscii() throws {
        let frame = UlanziFrame(duration: 5, text: [UlanziText(content: "héllo")])
        let json = try UlanziScene(frames: [frame]).jsonObject()
        // 'é' falls outside 0x20–0x7E; the content inside the element is what
        // is cleaned — the element's own shape stays.
        let text = json["text"] as? [[String: Any]]
        let content = text?[0]["content"] as? String
        #expect(
            content?.allSatisfy { character in
                character.asciiValue.map { (0x20...0x7E).contains($0) } == true
            } == true
        )
        #expect(text?[0]["fontHeight"] as? Int == 10)  // one element, still an object
    }

    // -- idle scene (D4) ------------------------------------------------------

    @Test func idleSceneIsOneFrameWithAMarker() throws {
        let json = try UlanziScene.idle.jsonObject()
        #expect((json["draw"] as? [[String: Any]])?.count == 1)   // one db: the dim dot
    }
}
