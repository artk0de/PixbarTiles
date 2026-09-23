import AppKit
import PixelClockKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The tile preview draws the clock's pixels as squares. It was an
// `NSImageView` scaling a 52×16 GIF up six times, and `NSImageView` draws
// through its cell with the context's own interpolation — the layer's
// nearest-neighbour filter never applied, and the face came out as a blur
// whose top row read as clipped. These pin the two halves: the GIF comes
// apart into the frames and the timing it carries, and a frame is drawn with
// every clock pixel a hard-edged square.

private func canvas(_ paint: (inout PixelCanvas) -> Void) -> PixelCanvas {
    var canvas = PixelCanvas()
    paint(&canvas)
    return canvas
}

private let red = Pixel(red: 255, green: 0, blue: 0)
private let blue = Pixel(red: 0, green: 0, blue: 255)

@Suite struct PixelPreviewFramesTests {
    @Test func aGifComesApartIntoItsFramesAndItsTiming() throws {
        let frames = [
            canvas { $0.drawRect(PixelRect(x: 0, y: 0, width: 1, height: 1), color: red) },
            canvas { $0.drawRect(PixelRect(x: 1, y: 0, width: 1, height: 1), color: red) },
            canvas { $0.drawRect(PixelRect(x: 2, y: 0, width: 1, height: 1), color: red) },
        ]
        let gif = try FullFrameGif.encode(frames: frames, delay: 0.08)

        let decoded = try #require(PixelPreviewFrames(gif: gif))

        #expect(decoded.images.count == 3)
        #expect(decoded.images.allSatisfy { $0.width == PixelCanvas.width })
        #expect(decoded.images.allSatisfy { $0.height == PixelCanvas.height })
        #expect(abs(decoded.delay - 0.08) < 0.005)
    }

    // A page that dwells and then moves carries a delay per frame, and the
    // preview reads each one: the usage face holds its percentages for
    // seconds and steps its marquee at a tenth.
    @Test func everyFrameKeepsItsOwnDelay() throws {
        let frames = [
            canvas { $0.drawRect(PixelRect(x: 0, y: 0, width: 1, height: 1), color: red) },
            canvas { $0.drawRect(PixelRect(x: 1, y: 0, width: 1, height: 1), color: red) },
            canvas { $0.drawRect(PixelRect(x: 2, y: 0, width: 1, height: 1), color: red) },
        ]
        let gif = try FullFrameGif.encode(frames: frames, delays: [10, 0.1, 1.5])

        let decoded = try #require(PixelPreviewFrames(gif: gif))

        #expect(decoded.delays.count == 3)
        for (read, written) in zip(decoded.delays, [10, 0.1, 1.5]) {
            #expect(abs(read - written) < 0.005)
        }
    }

    // Which frame shows at a moment of the loop: the one whose stretch of the
    // cycle the moment falls in — ten seconds of the first, a tenth of the
    // second, then the third, then round again.
    @Test func theFrameShownIsTheOneWhoseStretchTheMomentFallsIn() {
        let delays: [TimeInterval] = [10, 0.1, 1.5]
        #expect(PixelPreview.frameIndex(at: 0, delays: delays) == 0)
        #expect(PixelPreview.frameIndex(at: 9.99, delays: delays) == 0)
        #expect(PixelPreview.frameIndex(at: 10.05, delays: delays) == 1)
        #expect(PixelPreview.frameIndex(at: 10.2, delays: delays) == 2)
        #expect(PixelPreview.frameIndex(at: 11.65, delays: delays) == 0)
    }

    @Test func bytesThatAreNotAPictureAreNoFrames() {
        #expect(PixelPreviewFrames(gif: Data("not a gif".utf8)) == nil)
    }
}

@MainActor @Suite struct PixelPreviewDrawingTests {
    /// Two neighbouring clock pixels, red then blue, drawn six points each.
    /// On a hard edge the last device pixel of the red square is red and the
    /// first of the blue square is blue; smoothed, both are a purple blend.
    @Test func everyClockPixelIsAHardEdgedSquare() throws {
        let face = canvas {
            $0.drawRect(PixelRect(x: 0, y: 0, width: 1, height: 16), color: red)
            $0.drawRect(PixelRect(x: 1, y: 0, width: 1, height: 16), color: blue)
        }
        let frames = try #require(
            PixelPreviewFrames(gif: FullFrameGif.encode(frames: [face], delay: 5))
        )
        let scale: CGFloat = 6
        let host = NSHostingView(rootView: PixelPreview(frames: frames, scale: scale))
        host.frame = NSRect(
            x: 0, y: 0,
            width: CGFloat(PixelCanvas.width) * scale, height: CGFloat(PixelCanvas.height) * scale
        )
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let perPoint = CGFloat(rep.pixelsWide) / host.bounds.width
        let edge = Int((scale * perPoint).rounded())
        let row = rep.pixelsHigh / 2
        let lastRed = try #require(rep.colorAt(x: edge - 1, y: row)?.usingColorSpace(.sRGB))
        let firstBlue = try #require(rep.colorAt(x: edge, y: row)?.usingColorSpace(.sRGB))

        #expect(lastRed.redComponent > 0.9 && lastRed.blueComponent < 0.1, "\(lastRed)")
        #expect(firstBlue.blueComponent > 0.9 && firstBlue.redComponent < 0.1, "\(firstBlue)")
    }
}
