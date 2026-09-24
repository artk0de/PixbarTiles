// swiftc Sources/PixbarTilesApp/MenuBarGlyph.swift Sources/PixbarTilesApp/AppIconArt.swift Scripts/MakeIcon.swift -o build/icon-maker && build/icon-maker
//
// Renders the app icon set and the menu bar glyph from code.
//
//     Scripts/bundle.sh            # compiles and runs this as part of bundling
//
// Both marks are the PixbarTiles brand approved on 2026-09-24: a pixel P on a
// screen. Their geometry lives in `Sources/PixbarTilesApp/MenuBarGlyph.swift`
// (the glyph, and the P both marks share) and `AppIconArt.swift` (the icon) —
// those files are compiled into this tool AND into the app target, so the art
// the bundle ships and the art the tests pin cannot drift apart. The glyph
// arrives here already rasterized, exact-area per device pixel; the icon
// arrives as marks, drawn here with CG's antialiasing. Top-level statements
// live in `MakeIcon.main` because a multi-file compile only reads them from
// `main.swift`.
//
// Deterministic by construction: the geometry is data and every drawing is a
// pure function of it, so two runs produce byte-identical art, and a diff
// means someone changed the design.

import AppKit

func makeContext(_ size: Int) -> CGContext { makeContext(size, size) }

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func write(_ ctx: CGContext, to path: String) {
    write(ctx.makeImage()!, to: path)
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

let SRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: - The menu bar glyph

/// The raster into a CG image, byte for byte: sRGB, 8 bits a component,
/// straight alpha, rows top-down as CG images store them. No context and no
/// drawing in between, so the PNG holds exactly the pixels the tests pin.
func renderGlyph(_ state: PixbarGlyph.State, _ appearance: PixbarGlyph.Appearance,
                 scale: Int) -> CGImage {
    let raster = PixbarGlyph.raster(state, appearance: appearance, scale: scale)
    var bytes = [UInt8]()
    bytes.reserveCapacity(raster.pixels.count * 4)
    for pixel in raster.pixels {
        bytes += [UInt8((pixel.rgb >> 16) & 0xFF), UInt8((pixel.rgb >> 8) & 0xFF),
                  UInt8(pixel.rgb & 0xFF), pixel.alpha]
    }
    return CGImage(
        width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: raster.width * 4, space: SRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

/// Which bar each appearance is drawn for, for the previews.
func barColour(_ appearance: PixbarGlyph.Appearance) -> UInt32 {
    appearance == .dark ? 0x1C1C1E : 0xE8E8EA
}

/// The six variants where they will live: a light and a dark menu bar, each
/// with its appearance's glyph online, offline and empty — the no-clock
/// screen — at true 2x. The view a human eyeballs without opening eighteen
/// PNG files, laid out like the oracle page's bars.
func drawGlyphContext() -> CGContext {
    let scale = 2, barHeight = 24 * scale, gap = 12 * scale
    let glyphWidth = PixbarGlyph.width * scale, glyphHeight = PixbarGlyph.height * scale
    let barWidth = gap + (glyphWidth + gap) * 3
    let ctx = makeContext(barWidth + gap * 2, barHeight * 2 + gap * 3)
    ctx.setFillColor(colour(0x9A9A9A))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (index, appearance) in [PixbarGlyph.Appearance.light, .dark].enumerated() {
        let y = gap + (barHeight + gap) * index
        ctx.setFillColor(colour(barColour(appearance)))
        ctx.fill(CGRect(x: gap, y: y, width: barWidth, height: barHeight))
        for (slot, state) in PixbarGlyph.State.allCases.enumerated() {
            ctx.draw(renderGlyph(state, appearance, scale: scale), in: CGRect(
                x: gap * 2 + (glyphWidth + gap) * slot, y: y + (barHeight - glyphHeight) / 2,
                width: glyphWidth, height: glyphHeight
            ))
        }
    }
    return ctx
}

/// Every @2x variant magnified with interpolation off, on its own bar's
/// colour, so the actual device pixels are visible rather than the smoothed
/// impression of them.
func drawGlyphZoom() -> CGContext {
    let magnify = 6, margin = 12
    let wide = PixbarGlyph.width * 2 * magnify, high = PixbarGlyph.height * 2 * magnify
    let ctx = makeContext(margin + (wide + margin) * 3, margin + (high + margin) * 2)
    ctx.setFillColor(colour(0x9A9A9A))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.interpolationQuality = .none
    for (row, appearance) in [PixbarGlyph.Appearance.light, .dark].enumerated() {
        for (col, state) in PixbarGlyph.State.allCases.enumerated() {
            let frame = CGRect(x: margin + (wide + margin) * col, y: margin + (high + margin) * row,
                               width: wide, height: high)
            ctx.setFillColor(colour(barColour(appearance)))
            ctx.fill(frame)
            ctx.draw(renderGlyph(state, appearance, scale: 2), in: frame)
        }
    }
    return ctx
}

// MARK: - The app icon

/// The app icon at `size` pixels: `PixbarIcon`'s marks in order — the plate,
/// the 17 x 17 dots, the sparkle's squares — each filled by CG with its
/// antialiasing. The context is flipped so the marks' y-down coordinates are
/// the oracle page's own.
func drawAppIcon(size: Int) -> CGContext {
    let ctx = makeContext(size)
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    for mark in PixbarIcon.marks(size: size) {
        ctx.setFillColor(colour(mark.rgb, alpha: CGFloat(mark.alpha)))
        switch mark.shape {
        case let .roundedRect(r, radius):
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            ctx.fillPath()
        case let .circle(x, y, radius):
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                       width: radius * 2, height: radius * 2))
        case let .rect(r):
            ctx.fill(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
    }
    return ctx
}

/// Kept as the record of a settled question: art drawn directly at the target
/// size (left) against the full-size art resampled down to it (right). The
/// iconset resamples; this sheet is where that choice is checked against the
/// art it is applied to.
func drawSmallComparison() -> CGContext {
    let sheet = 420
    let ctx = makeContext(sheet)
    ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: sheet, height: sheet))

    let detailed = drawAppIcon(size: 512).makeImage()!
    var y = sheet - 150
    for target in [128, 64, 32] {
        // Both candidates must be produced AT the target size and only then
        // magnified, or the sheet compares one of them against itself.
        let resampled = makeContext(target)
        resampled.interpolationQuality = .high
        resampled.draw(detailed, in: CGRect(x: 0, y: 0, width: target, height: target))

        ctx.interpolationQuality = .none
        ctx.draw(drawAppIcon(size: target).makeImage()!,
                 in: CGRect(x: 40, y: CGFloat(y), width: 128, height: 128))
        ctx.draw(resampled.makeImage()!,
                 in: CGRect(x: 240, y: CGFloat(y), width: 128, height: 128))
        y -= 140
    }
    return ctx
}

@main
struct MakeIcon {
    static func main() {
        let out = "build/icon"
        try! FileManager.default.createDirectory(atPath: "\(out)/AppIcon.iconset", withIntermediateDirectories: true)

        // Drawn once at full size and resampled down, rather than redrawn per
        // size: the spec draws the master at 1024, and at the small sizes a
        // redrawn grid rounds its cell to one or two pixels and loses the dots.
        let master = drawAppIcon(size: 1024).makeImage()!
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                (256, 1), (256, 2), (512, 1), (512, 2)] {
            let pixels = points * scale
            let suffix = scale == 1 ? "" : "@2x"
            let target = makeContext(pixels)
            target.interpolationQuality = .high
            target.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            write(target, to: "\(out)/AppIcon.iconset/icon_\(points)x\(points)\(suffix).png")
        }

        // Menu bar: both appearances and all three device states at 1x/2x/3x.
        // The names are the ones `NSImage(named:)` resolves from loose files in
        // `Contents/Resources` — the 1x file carries no scale suffix, the @2x
        // and @3x do — and the ones the `AppGlyph` drawings name. `empty` is
        // the no-clock screen.
        for (scale, suffix) in [(1, ""), (2, "@2x"), (3, "@3x")] {
            for appearance in PixbarGlyph.Appearance.allCases {
                for state in PixbarGlyph.State.allCases {
                    write(renderGlyph(state, appearance, scale: scale),
                          to: "\(out)/pixbar-glyph-\(appearance)-\(state)\(suffix).png")
                }
            }
        }

        // Previews, purely so a human can eyeball the result without opening ten
        // files: the app icon at full size and at a Dock-ish 256, the menu bar
        // variants on the bars themselves and magnified with interpolation off.
        write(master, to: "\(out)/preview-appicon-1024.png")
        let quarter = makeContext(256)
        quarter.interpolationQuality = .high
        quarter.draw(master, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        write(quarter, to: "\(out)/preview-appicon-256.png")
        write(drawGlyphContext(), to: "\(out)/preview-menubar-context.png")
        write(drawGlyphZoom(), to: "\(out)/preview-menubar-zoom.png")
        write(drawSmallComparison(), to: "\(out)/preview-small-comparison.png")

        print("wrote \(out)")
    }
}
