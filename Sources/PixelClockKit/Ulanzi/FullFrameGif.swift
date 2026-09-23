import Foundation

/// The full-frame GIF89a writer — the port of `Scripts/MakeTimedGif.py`'s
/// assembly, which the live TC002 panel accepted on 2026-09-21.
///
/// FULL 52×16 frames, one global palette, no local tables, no per-frame
/// cropping. That shape is the whole point: ImageIO's writer crops frames to
/// the changed region and relies on the decoder holding the previous frame,
/// and the stock decoder paints those sub-rects over the accumulated picture
/// instead — crossing marquees smear within seconds. A hand-assembled
/// full-frame GIF renders pixel-stable, which is what this writer ships.
///
/// Deterministic by construction: the palette is built in first-seen order
/// across the frames (black seated at index 0 first, exactly as the script
/// seats it), and the LZW is table-driven with no time in it. The same frames
/// encode to the same bytes — the property the tile-settings preview stands
/// on, and the reason its test can demand byte-identical output.
public enum FullFrameGif {
    public enum EncodingError: Error, Equatable {
        /// No frames at all: an empty file is not a GIF.
        case noFrames
        /// A palette has 256 slots. Frames needing more are refused loudly —
        /// silently re-colouring them would make a preview lie about colour.
        case paletteOverflow
        /// Frames of more than one canvas size: one GIF plays on one panel.
        case mixedFrameSizes
        /// A delay list that is not one figure per frame: which frame a stray
        /// figure belongs to would be a guess.
        case mismatchedDelays
    }

    /// Encodes `frames` as one animated GIF89a, every frame shown for
    /// `delay` seconds — the per-frame spelling with the one figure repeated,
    /// so the bytes are exactly what they were before frames had their own.
    public static func encode(frames: [PixelCanvas], delay: TimeInterval) throws -> Data {
        try encode(frames: frames, delays: Array(repeating: delay, count: frames.count))
    }

    /// Encodes `frames` as one animated GIF89a, frame `i` shown for
    /// `delays[i]` seconds.
    ///
    /// Per frame because a page that moves and then rests is the ordinary
    /// shape: a marquee steps at a tenth of a second and dwells for seconds
    /// at either end, and a dwell is ONE frame with a long delay rather than
    /// the same frame repeated — repeats would spend the panel's frame
    /// ceiling on standing still.
    ///
    /// The GIF's size is the FIRST frame's: a preview of a TC002 tile encodes
    /// 52×16 canvases, an AWTRIX tile's 32×16, and the file says which it is.
    /// The frames share one clock's panel, so a later frame of another size is
    /// refused rather than smeared across a screen it does not fit.
    public static func encode(frames: [PixelCanvas], delays: [TimeInterval]) throws -> Data {
        guard frames.isEmpty == false else { throw EncodingError.noFrames }
        guard delays.count == frames.count else { throw EncodingError.mismatchedDelays }
        let frameWidth = frames[0].width, frameHeight = frames[0].height
        let framePixels = frameWidth * frameHeight
        guard frames.allSatisfy({ $0.width == frameWidth && $0.height == frameHeight }) else {
            throw EncodingError.mixedFrameSizes
        }

        // The palette in first-seen order, black seated at index 0 before
        // anything else — the same seat the script gives it, and the index
        // the graphic control extension names as its (unused) transparent
        // one. A parallel dictionary answers lookups; the array keeps the
        // order a dictionary would silently lose.
        var paletteOrder: [Pixel] = [.black]
        var paletteIndex: [Pixel: UInt16] = [.black: 0]
        var indexed: [UInt8] = []
        indexed.reserveCapacity(frames.count * framePixels)
        for canvas in frames {
            for y in 0..<frameHeight {
                for x in 0..<frameWidth {
                    let pixel = canvas[x, y]
                    if let known = paletteIndex[pixel] {
                        indexed.append(UInt8(known))
                        continue
                    }
                    guard paletteOrder.count < 256 else {
                        throw EncodingError.paletteOverflow
                    }
                    paletteIndex[pixel] = UInt16(paletteOrder.count)
                    paletteOrder.append(pixel)
                    indexed.append(UInt8(paletteOrder.count - 1))
                }
            }
        }

        var gif: [UInt8] = []
        // Header, then the logical screen descriptor: the frame's size as
        // two little-endian 16-bit words, and 0xF7 — global colour table
        // present, 256 entries.
        gif.append(contentsOf: Array("GIF89a".utf8))
        gif.append(contentsOf: [UInt8(frameWidth & 0xFF), UInt8(frameWidth >> 8),
                                UInt8(frameHeight & 0xFF), UInt8(frameHeight >> 8),
                                0xF7, 0, 0])
        // The global table, all 256 slots — every colour the frames used in
        // first-seen order, then black padding to the end.
        for slot in 0..<256 {
            if slot < paletteOrder.count {
                gif.append(contentsOf: [paletteOrder[slot].red, paletteOrder[slot].green,
                                        paletteOrder[slot].blue])
            } else {
                gif.append(contentsOf: [0, 0, 0])
            }
        }
        // The NETSCAPE loop extension: the pages cycle for ever rather than
        // stopping after one pass.
        gif.append(contentsOf: [0x21, 0xFF, 11])
        gif.append(contentsOf: Array("NETSCAPE2.0".utf8))
        gif.append(contentsOf: [3, 1, 0, 0, 0])

        // Each frame's delay in centiseconds — the unit the graphic control
        // extension speaks, sixteen bits of it.
        let width = UInt8(frameWidth & 0xFF), height = UInt8(frameHeight & 0xFF)
        var start = 0
        let count = framePixels
        for delay in delays {
            let centiseconds = max(0, min(0xFFFF, Int((delay * 100).rounded())))
            // GCE: packed 0x04 (do not dispose), the delay, and the block
            // terminator — then the image descriptor: a FULL frame at (0,0),
            // no local table, no interlace.
            gif.append(contentsOf: [0x21, 0xF9, 4, 0x04,
                                    UInt8(centiseconds & 0xFF), UInt8((centiseconds >> 8) & 0xFF),
                                    0, 0])
            gif.append(contentsOf: [0x2C, 0, 0, 0, 0,
                                    width, UInt8(PixelCanvas.width >> 8),
                                    height, UInt8(PixelCanvas.height >> 8), 0])
            gif.append(8)  // LZW minimum code size
            let blob = lzw(Array(indexed[start..<(start + count)]))
            var cursor = 0
            while cursor < blob.count {
                let chunk = blob[cursor..<min(cursor + 255, blob.count)]
                gif.append(UInt8(chunk.count))
                gif.append(contentsOf: chunk)
                cursor += 255
            }
            gif.append(0)
            start += count
        }
        gif.append(0x3B)
        return Data(gif)
    }

    /// GIF variable-width LZW, in the classic (Poskanzer) convention the
    /// stock decoder speaks: the encoder grows its code width one code LATER
    /// than the decoder adds the same entry — growth happens only once the
    /// entry numbered `1 << width` itself exists.
    ///
    /// Codes 0–255 are the literals, 256 the clear code, 257 the end-of-
    /// information code; the first table entry any encoder adds is 258.
    private static func lzw(_ pixels: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var bitBuffer = 0
        var bitCount = 0

        func emit(_ code: Int, _ width: Int) {
            bitBuffer |= code << bitCount
            bitCount += width
            while bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        var width = 9
        var table: [Data: Int] = {
            var initial: [Data: Int] = [:]
            for byte in 0..<256 { initial[Data([UInt8(byte)])] = byte }
            return initial
        }()
        emit(256, width)  // clear: every decoder starts from the literals
        var phrase = Data()
        for pixel in pixels {
            let next = phrase + Data([pixel])
            if table[next] != nil {
                phrase = next
                continue
            }
            emit(table[phrase]!, width)
            let code = table.count + 2
            table[next] = code
            if code == 1 << width, width < 12 {
                width += 1
            }
            phrase = Data([pixel])
        }
        if phrase.isEmpty == false {
            emit(table[phrase]!, width)
        }
        emit(257, width)
        if bitCount > 0 {
            out.append(UInt8(bitBuffer & 0xFF))
        }
        return out
    }
}
