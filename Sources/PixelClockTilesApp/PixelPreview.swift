import ImageIO
import SwiftUI

/// A preview GIF taken apart: its frames, and how long each one is shown.
///
/// The preview used to hand the GIF to an `NSImageView` and let it scale and
/// animate. `NSImageView` draws through its cell with the graphics context's
/// own interpolation, so the nearest-neighbour filter set on its layer never
/// applied: a 52×16 face magnified six times came out smoothed, every edge a
/// ramp, and the top row of a digit read as cut off. Taking the frames out is
/// what lets the view below draw them as squares.
struct PixelPreviewFrames: Equatable {
    let images: [CGImage]
    /// Seconds per frame. One value, because the encoder writes one:
    /// `FullFrameGif` gives every frame the same delay.
    let delay: TimeInterval

    /// Nil for bytes that are not a picture — a preview that cannot be read
    /// is the preview's note to explain, not a crash to have.
    init?(gif: Data) {
        guard
            let source = CGImageSourceCreateWithData(gif as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let count = CGImageSourceGetCount(source)
        let images = (0..<count).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        guard images.count == count else { return nil }
        self.images = images
        self.delay = Self.delay(of: source)
    }

    /// The first frame's delay, unclamped: ImageIO clamps anything under a
    /// tenth of a second UP to a tenth in `DelayTime`, and the scroll's 0.08 is
    /// exactly the kind of figure that clamping would slow down.
    private static func delay(of source: CGImageSource) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
        guard let delay, delay > 0 else { return 1 }
        return delay
    }
}

/// The clock's face at whole-pixel magnification: every clock pixel a
/// hard-edged square, animating when there is more than one frame.
///
/// The squares are drawn HERE, not asked of the renderer. `Image` with
/// `.interpolation(.none)` was the first answer, and the offscreen path still
/// smoothed it — a red pixel beside a blue one came back purple on both sides
/// of the seam. So each frame is magnified once, nearest-neighbour, in a
/// bitmap context of our own, to twice the point scale: every clock-pixel seam
/// then lands on a whole device pixel on a 1x screen and on a 2x one, and
/// whatever filter the renderer applies has nothing to blend across.
///
/// A `TimelineView` does the animation, stepping at the GIF's own delay, so a
/// scroll plays at the rate the clock plays it.
struct PixelPreview: View {
    private let magnified: [CGImage]
    private let delay: TimeInterval
    private let size: CGSize

    /// `scale` is points per clock pixel.
    init(frames: PixelPreviewFrames, scale: CGFloat) {
        let factor = Int((scale * Self.backingHeadroom).rounded())
        magnified = frames.images.compactMap { Self.magnify($0, by: factor) }
        delay = frames.delay
        let first = frames.images.first
        size = CGSize(
            width: CGFloat(first?.width ?? 0) * scale, height: CGFloat(first?.height ?? 0) * scale
        )
    }

    /// Device pixels per point the magnified frame is built for. Two covers
    /// every Retina display and divides evenly back down to a 1x one.
    private static let backingHeadroom: CGFloat = 2

    var body: some View {
        if magnified.count > 1 {
            TimelineView(.periodic(from: .now, by: delay)) { context in
                square(magnified[index(at: context.date)])
            }
        } else if let only = magnified.first {
            square(only)
        }
    }

    private func index(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / delay) % magnified.count
    }

    private func square(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: size.width, height: size.height)
    }

    /// Every source pixel as a `factor`×`factor` block, no filtering.
    private static func magnify(_ image: CGImage, by factor: Int) -> CGImage? {
        guard factor > 0 else { return nil }
        let width = image.width * factor, height = image.height * factor
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
