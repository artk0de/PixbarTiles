// Tests/PixelClockKitTests/ClaudeUsageConnectorTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The TC002 face of the Claude usage connector. The AWTRIX face's tests live
// beside the other faces in ConnectorFaceTests; the TC002 half has its own
// raster to pin.

@Suite struct ClaudeTC002FaceTests {
    func makeConnector() -> ClaudeUsageConnector {
        ClaudeUsageConnector(reporter: Reports(reading: nil))
    }

    /// Answers with one fixed reading; the face is tested against a reading,
    /// never against the network.
    private struct Reports: ClaudeUsageReporting {
        let reading: ClaudeUsageReading?
        func read() async throws -> ClaudeUsageReading? { reading }
    }

    func face(_ utilization: Int) -> UlanziFace<ClaudeUsageReading>? {
        let connector = ClaudeUsageConnector(
            reporter: Reports(reading: ClaudeUsageReading(utilization: utilization, resetsAt: nil))
        )
        return connector.ulanziFace
    }

    /// The star rides as the image layer beside the rastered percentage.
    @Test func oneBitmapAndTheStarAsTheImageLayer() throws {
        let delivery = try #require(face(87)?.draw(ClaudeUsageReading(utilization: 87, resetsAt: nil)))
        let frame = delivery.scene.frames[0]
        #expect(delivery.scene.frames.count == 1)
        #expect(frame.draw.count == 1)   // the single db (D2)
        guard case .bitmap = try #require(frame.draw.first) else {
            Issue.record("not a bitmap")
            return
        }
        let star = try #require(frame.image.first)
        let bytes = try #require(Data(base64Encoded: star.base64))
        // The real GIF: decoded bytes start with the GIF89a magic.
        #expect(String(decoding: bytes.prefix(6), as: UTF8.self) == "GIF89a")
    }

    /// Declared metadata sits inside every measured limit (A4), so the scene
    /// the face builds always encodes.
    @Test func declaredMetadataRespectsTheLimits() throws {
        let delivery = try #require(face(140)?.draw(ClaudeUsageReading(utilization: 140, resetsAt: nil)))
        let frame = delivery.scene.frames[0]
        let star = try #require(frame.image.first)

        #expect(star.isAnimated)
        #expect(star.frameCount <= 50)
        #expect(star.pixelSize.width <= 256)
        #expect(star.pixelSize.height <= 256)
        #expect(star.base64.utf8.count <= 60_000)
        // And the scene carries it: an overage reading past a hundred is a
        // true thing to say, and the encoder takes it.
        #expect((try UlanziScene(frames: [frame]).jsonObject()).isEmpty == false)
    }

    @Test func brandColourInksTheDigits() throws {
        let delivery = try #require(face(87)?.draw(ClaudeUsageReading(utilization: 87, resetsAt: nil)))
        let draw = try #require(delivery.scene.frames[0].draw.first)
        guard case let .bitmap(width, _, pixels, _) = draw else {
            Issue.record("not a bitmap")
            return
        }
        let brand = UlanziColour(hex: ClaudeUsage.brandColour).value
        #expect(pixels.contains(brand), "no pixel inked \(String(brand, radix: 16))")
        _ = width
    }

    // 87% at scale 2, the glyphs the font actually carries:
    //
    //   ######..######..##....
    //   ##..##......##......##
    //   ######......##....##..
    //   ##..##......##..##....
    //   ######......##......##
    //
    // each font row doubled on the way to the panel.
    @Test func eightySevenPercentRastersThroughTheFont() throws {
        let delivery = try #require(face(87)?.draw(ClaudeUsageReading(utilization: 87, resetsAt: nil)))
        let rows = goldenASCII(of: try #require(delivery.scene.frames[0].draw.first))
        #expect(
            rows
                == [
                    "######..######..##....",
                    "######..######..##....",
                    "##..##......##......##",
                    "##..##......##......##",
                    "######......##....##..",
                    "######......##....##..",
                    "##..##......##..##....",
                    "##..##......##..##....",
                    "######......##......##",
                    "######......##......##",
                ]
        )
    }
}
