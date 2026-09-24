import CoreGraphics
import Foundation
import ImageIO
import PixbarKit
import Testing

// The full-frame GIF89a writer, measured against the two things it must be:
// pixel-exact on the way back through ImageIO — the oracle the live panel
// accepted on 2026-09-21 — and byte-identical for the same frames, which is
// what makes a preview built on it honest rather than usually right.

private func solid(_ colour: Pixel) -> PixelCanvas {
    var canvas = PixelCanvas()
    canvas.fill(colour)
    return canvas
}

private func speckled(_ ink: Pixel) -> PixelCanvas {
    var canvas = PixelCanvas()
    for y in 0..<PixelCanvas.height where y % 2 == 0 {
        for x in 0..<PixelCanvas.width where (x + y) % 3 == 0 {
            canvas[x, y] = ink
        }
    }
    return canvas
}

/// Decodes a GIF the way a decoder meets it, frame by frame, into RGBA bytes.
private func decodedFrames(_ gif: Data) -> [(size: CGSize, rgba: [UInt8], delay: Double)] {
    let source = CGImageSourceCreateWithData(gif as CFData, nil)!
    let count = CGImageSourceGetCount(source)
    return (0..<count).map { index in
        let image = CGImageSourceCreateImageAtIndex(source, index, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let delay = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let seconds = delay?[kCGImagePropertyGIFDelayTime] as? Double ?? -1
        let width = image.width
        let height = image.height
        // No external buffer handed to the context: `CGContext(data:)` does
        // not copy, and a pointer borrowed from a Swift array dies with the
        // call — the drawing would land in memory this function no longer
        // reads. The context owns its store; the pixels are copied out after.
        let context = CGContext(
            data: nil,
            width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let held = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let pixels = Array(UnsafeBufferPointer(start: held, count: width * height * 4))
        return (CGSize(width: width, height: height), pixels, seconds)
    }
}

@Suite struct FullFrameGifTests {
    // The spec's preview-determinism anchor, at the encoder's own level: the
    // same frames encode to the same bytes, again and every time, because the
    // palette is built in first-seen order and the LZW is table-driven.
    @Test func theSameFramesEncodeToTheSameBytesEveryTime() throws {
        let frames = [solid(.black), speckled(Pixel(red: 255, green: 0, blue: 0))]

        let first = try FullFrameGif.encode(frames: frames, delay: 0.5)
        let second = try FullFrameGif.encode(frames: frames, delay: 0.5)
        #expect(first == second)
    }

    // The preview of an AWTRIX tile is a 32×16 canvas: the GIF carries the
    // canvas's own size in its logical screen descriptor, not the TC002
    // panel's, and the pixels survive at the smaller geometry.
    @Test func theGifCarriesTheFirstFramesSizeNotThePanels() throws {
        var canvas = PixelCanvas(width: 32, height: 16)
        canvas[31, 15] = Pixel(red: 1, green: 2, blue: 3)

        let gif = try FullFrameGif.encode(frames: [canvas], delay: 5)
        let bytes = [UInt8](gif)
        // The logical screen descriptor, little-endian pairs, after the
        // six-byte header.
        #expect(bytes[6] == 32 && bytes[7] == 0)
        #expect(bytes[8] == 16 && bytes[9] == 0)

        let frame = try #require(decodedFrames(gif).first)
        #expect(frame.size == CGSize(width: 32, height: 16))
        // Canvas row 15 is the image's bottom row — the last in the buffer.
        let base = (15 * 32 + 31) * 4
        #expect(Array(frame.rgba[base..<base + 3]) == [1, 2, 3])
    }

    // THE rule the panel taught: FULL frames. ImageIO decodes either kind, so
    // the oracle is the frame's own size — a cropped frame comes back a
    // sub-rect, and this test fails on the size before it fails on a pixel.
    // The pixels themselves come back exactly, because the writer puts every
    // colour in a global palette and lets no local table between.
    @Test func everyFrameDecodesBackPixelExactAtFullPanelSize() throws {
        let frames = [
            solid(Pixel(red: 12, green: 200, blue: 7)),
            speckled(Pixel(red: 90, green: 40, blue: 200)),
            solid(Pixel(red: 255, green: 255, blue: 255)),
        ]
        let gif = try FullFrameGif.encode(frames: frames, delay: 5)

        let decoded = decodedFrames(gif)
        #expect(decoded.count == frames.count)
        for (frameIndex, (frame, canvas)) in zip(decoded, frames).enumerated() {
            #expect(frame.size == CGSize(width: PixelCanvas.width, height: PixelCanvas.height))
            #expect(frame.delay == 5)
            var mismatches: [String] = []
            for y in 0..<PixelCanvas.height {
                for x in 0..<PixelCanvas.width {
                    let pixel = canvas[x, y]
                    let offset = (y * PixelCanvas.width + x) * 4
                    if frame.rgba[offset] != pixel.red
                        || frame.rgba[offset + 1] != pixel.green
                        || frame.rgba[offset + 2] != pixel.blue {
                        mismatches.append(
                            "frame \(frameIndex) (\(x),\(y)) got "
                                + "\(frame.rgba[offset]),\(frame.rgba[offset + 1]),\(frame.rgba[offset + 2])"
                                + " want \(pixel.red),\(pixel.green),\(pixel.blue)"
                        )
                    }
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches.prefix(4))")
        }
    }

    // The wire facts the stock decoder was measured to need: the format named,
    // the loop extension that keeps the pages cycling, and the trailer that
    // ends the file.
    @Test func theBytesNameTheFormatLoopForEverAndEndProperly() throws {
        let gif = try FullFrameGif.encode(frames: [solid(.black)], delay: 0.1)

        #expect(gif.prefix(6) == Data("GIF89a".utf8))
        #expect(gif.range(of: Data("NETSCAPE2.0".utf8)) != nil)
        #expect(gif.last == 0x3B)
    }

    // The screen descriptor carries the panel's own size, little-endian, and
    // the 256-entry global table flag — the byte the device decoder reads
    // before it reads anything else.
    @Test func theScreenDescriptorNamesThePanelSize() throws {
        let gif = try FullFrameGif.encode(frames: [solid(.black)], delay: 0.1)

        // "GIF89a" then width low, width high, height low, height high.
        #expect(Array(gif.prefix(10).dropFirst(6)) == [52, 0, 16, 0])
    }

    // One delay for every frame, in centiseconds — the unit the wire speaks,
    // carried per frame in the graphic control extension.
    @Test func theDelayTravelsWithEveryFrame() throws {
        let gif = try FullFrameGif.encode(
            frames: [solid(.black), speckled(.white)], delay: 0.12
        )

        for frame in decodedFrames(gif) {
            #expect(abs(frame.delay - 0.12) < 0.001)
        }
    }

    // Per-frame delays: a marquee steps at a tenth of a second and dwells for
    // seconds at either end, and a dwell is ONE frame with a long delay — so
    // each frame carries its own figure, as far as the panel's longest page
    // (five minutes, 30 000 centiseconds, inside the GCE's 16 bits).
    @Test func eachFrameCarriesItsOwnDelay() throws {
        let gif = try FullFrameGif.encode(
            frames: [solid(.black), speckled(.white), speckled(.black), solid(.white)],
            delays: [1.0, 0.1, 1.5, 300]
        )

        let delays = decodedFrames(gif).map(\.delay)
        #expect(delays.count == 4)
        for (decoded, expected) in zip(delays, [1.0, 0.1, 1.5, 300]) {
            #expect(abs(decoded - expected) < 0.001)
        }
    }

    // One delay for every frame is the per-frame spelling with the figure
    // repeated — the same bytes, so every face written before per-frame
    // delays encodes exactly as it did.
    @Test func oneDelayIsThePerFrameSpellingRepeated() throws {
        let frames = [solid(.black), speckled(.white)]
        #expect(
            try FullFrameGif.encode(frames: frames, delay: 0.12)
                == FullFrameGif.encode(frames: frames, delays: [0.12, 0.12])
        )
    }

    // A delay list that does not match the frames is refused: which frame a
    // stray figure belongs to would be a guess.
    @Test func delaysThatDoNotMatchTheFramesAreRefused() {
        #expect(throws: FullFrameGif.EncodingError.mismatchedDelays) {
            try FullFrameGif.encode(frames: [solid(.black), solid(.white)], delays: [0.1])
        }
    }

    // A palette has 256 slots. A frame set that needs more is refused loudly
    // rather than silently re-coloured — a preview that quietly lies about
    // colour is worse than no preview.
    @Test func moreThanTwoHundredFiftySixColoursIsRefusedRatherThanRecoloured() {
        // Every pixel its own colour: 52 × 16 = 832 distinct, far past the
        // palette's end.
        var canvas = PixelCanvas()
        var next = 0
        for y in 0..<PixelCanvas.height {
            for x in 0..<PixelCanvas.width {
                canvas[x, y] = Pixel(red: UInt8(next & 0xFF), green: UInt8(next >> 8 & 0xFF), blue: 1)
                next += 1
            }
        }

        #expect(throws: FullFrameGif.EncodingError.paletteOverflow) {
            try FullFrameGif.encode(frames: [canvas], delay: 0.1)
        }
    }

    // And the empty file is not a GIF: no frames, no encode.
    @Test func encodingNothingIsRefused() {
        #expect(throws: FullFrameGif.EncodingError.noFrames) {
            try FullFrameGif.encode(frames: [], delay: 0.1)
        }
    }
}
