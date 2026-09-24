// swiftc Sources/PixbarTilesApp/MenuBarUserclock.swift Scripts/MakeIcon.swift -o build/icon-maker && build/icon-maker
//
// Renders the app icon set and the menu bar glyph from code.
//
//     Scripts/bundle.sh            # compiles and runs this as part of bundling
//
// Both marks are the user's own pixel-art clock, rasterized from the approved
// map in `Sources/PixbarTilesApp/MenuBarUserclock.swift` — that file is
// compiled into this tool AND into the app target, so the art the bundle ships
// and the art the tests pin cannot drift apart. The app icon sets the clock on
// the dark circular badge its source art sits on (the badge was dropped only
// for the tiny bar); the menu bar glyph is the bare clock. Top-level
// statements live in `MakeIcon.main` because a multi-file compile only reads
// them from `main.swift`.
//
// Deterministic by construction: the map and the palettes are data and every
// drawing is a pure function of them, so two runs produce byte-identical art,
// and a diff means someone changed the design.

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

// MARK: - The menu bar glyph: the user's clock

let SRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// The raster into a CG image, through the bitmap the approved generator drew
/// through: sRGB, 8 bits a component, every art pixel an opaque s x s fill on
/// whole device pixels. The rows are top-down and CG's are bottom-up, so an
/// art row lands at `(height - 1 - row) * scale` — the same arithmetic, cell
/// for cell, that produced the approved `userclock-*` files.
func renderClock(_ palette: UserClock.Palette, scale: Int) -> CGImage {
    let raster = UserClock.raster(palette: palette, scale: scale)
    let ctx = CGContext(
        data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8,
        bytesPerRow: raster.width * 4, space: SRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for (row, line) in UserClock.map.enumerated() {
        for col in 0..<line.count {
            let hex = raster.pixel(x: col * scale, y: row * scale)
            guard hex != 0 else { continue }
            ctx.setFillColor(CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            ))
            ctx.fill(CGRect(x: col * scale, y: (UserClock.height - 1 - row) * scale,
                            width: scale, height: scale))
        }
    }
    return ctx.makeImage()!
}

func colour(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The six variants where they will live: a light and a dark menu bar, each
/// with its appearance's glyph online, offline and empty — the no-clock
/// screen — at true 2x. The view a human eyeballs without opening eighteen
/// PNG files — the same role the drawn candidates' comparison sheet played
/// when the design was being chosen.
func drawUserClockContext() -> CGContext {
    let scale = 2, pt = 18 * scale, barHeight = 24 * scale, width = 240 * scale
    let ctx = makeContext(width)
    ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: width))

    let bars: [(NSColor, [UserClock.Palette], CGFloat)] = [
        (colour(0xF2F2F2),
         [UserClock.lightOnline, UserClock.lightOffline, UserClock.empty(UserClock.lightOnline)],
         CGFloat(width - barHeight)),
        (colour(0x212121),
         [UserClock.darkOnline, UserClock.darkOffline, UserClock.empty(UserClock.darkOnline)],
         CGFloat(width - barHeight * 3)),
    ]
    for (background, palettes, y) in bars {
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(barHeight)))
        let inset = CGFloat(barHeight - pt) / 2
        for (index, palette) in palettes.enumerated() {
            let image = renderClock(palette, scale: scale)
            let x = CGFloat(width) - (CGFloat(image.width) + CGFloat(barHeight) / 2) * CGFloat(index + 1)
            ctx.draw(image, in: CGRect(x: x, y: y + inset, width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        }
    }
    return ctx
}

/// Every variant magnified with interpolation off, so the actual pixels are
/// visible rather than the smoothed impression of them.
func drawUserClockZoom() -> CGContext {
    let magnify = 4, margin = 12
    let wide = UserClock.width * magnify, high = UserClock.height * magnify
    let ctx = makeContext(margin + (wide + margin) * 6, high + margin * 2)
    ctx.setFillColor(colour(0xE8E8EA).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.interpolationQuality = .none
    for (index, palette) in [
        UserClock.lightOnline, UserClock.lightOffline, UserClock.empty(UserClock.lightOnline),
        UserClock.darkOnline, UserClock.darkOffline, UserClock.empty(UserClock.darkOnline),
    ].enumerated() {
        let x = margin + (wide + margin) * index
        ctx.draw(renderClock(palette, scale: 1),
                 in: CGRect(x: x, y: margin, width: wide, height: high))
    }
    return ctx
}

// MARK: - The app icon

/// The app icon: the user's clock on the dark circular badge its source art
/// sits on — the badge was dropped only for the tiny menu bar, and at
/// app-icon size it is what makes the mark read as an object rather than a
/// sticker. The badge fills the Big Sur content square (824/1024 of the
/// canvas); the clock rides on it at an integer art-pixel scale, every art
/// pixel a hard-edged square, so the badge and its halo are the only smooth
/// things in the drawing.
func drawAppIcon(size: Int) -> CGContext {
    let ctx = makeContext(size)
    let s = CGFloat(size)
    let inset = s * 0.098                      // Big Sur content inset
    let badge = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = badge.width / 2
    let centre = CGPoint(x: badge.midX, y: badge.midY)

    // The halo first, so the badge overlaps its inner half: the source art's
    // glow, translated to something that reads on a light Finder window as
    // well as in a dark Dock — a faint shadow ring around the rim, with the
    // two faintest of the source's concentric ripples standing in it.
    let halo = radius * 0.21
    ctx.drawRadialGradient(
        CGGradient(
            colorsSpace: SRGB,
            colors: [
                NSColor(white: 0, alpha: 0).cgColor,
                NSColor(white: 0, alpha: 0).cgColor,
                NSColor(white: 0, alpha: 0.16).cgColor,
                NSColor(white: 0, alpha: 0).cgColor,
            ] as CFArray,
            locations: [0, 0.80, 0.84, 1]
        )!,
        startCenter: centre, startRadius: 0, endCenter: centre,
        endRadius: radius + halo, options: []
    )
    for (offset, alpha) in [(1.055, CGFloat(0.05)), (1.105, CGFloat(0.03))] {
        let ring = radius * offset
        ctx.setStrokeColor(NSColor(white: 0.55, alpha: alpha).cgColor)
        ctx.setLineWidth(radius * 0.004)
        ctx.strokeEllipse(in: CGRect(
            x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2
        ))
    }

    // The badge: near-black with the sheen the source art carries — a lighter
    // crown a third of the radius above centre, falling to the rim — and a
    // hairline edge light, so the rim reads against the black page the art
    // came from as well as against a white one.
    ctx.saveGState()
    ctx.addPath(CGPath(ellipseIn: badge, transform: nil))
    ctx.clip()
    ctx.drawRadialGradient(
        CGGradient(
            colorsSpace: SRGB,
            colors: [
                NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1).cgColor,
                NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!,
        startCenter: CGPoint(x: centre.x, y: centre.y + radius * 0.35),
        startRadius: 0, endCenter: centre, endRadius: radius, options: []
    )
    let rim = radius * 0.012
    ctx.setLineWidth(rim)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.08).cgColor)
    ctx.strokeEllipse(in: badge.insetBy(dx: rim / 2, dy: rim / 2))
    ctx.restoreGState()

    // The clock: the map at the largest whole art-pixel scale that keeps it
    // within 58% of the badge — the proportion the source art holds — centred
    // on whole device pixels, so no art pixel is ever resampled. Dark is the
    // palette the source draws; Finder and the Dock put it on light ground,
    // where the light frame carries the silhouette.
    let scale = max(1, Int(badge.width * 0.58 / CGFloat(UserClock.width)))
    let art = renderClock(UserClock.darkOnline, scale: scale)
    let origin = CGPoint(
        x: CGFloat(Int(badge.minX) + (Int(badge.width) - art.width) / 2),
        y: CGFloat(Int(badge.minY) + (Int(badge.height) - art.height) / 2)
    )

    // A quiet drop shadow, so it sits ON the badge rather than in it.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -radius * 0.02), blur: radius * 0.06,
        color: NSColor(white: 0, alpha: 0.45).cgColor
    )
    ctx.draw(art, in: CGRect(
        x: origin.x, y: origin.y, width: CGFloat(art.width), height: CGFloat(art.height)
    ))
    ctx.restoreGState()
    return ctx
}

/// Kept as the record of a settled question: art drawn directly at the target
/// size (left) against the full-size art resampled down to it (right). The
/// right column won at every size, which is why the iconset resamples.
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

        // Drawn once at full size and resampled down, rather than redrawn per size.
        // Resampling was measured against per-size drawing and wins outright: the
        // clock survives legibly to 32px, where art drawn directly at that size
        // aliases into noise.
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

        // Menu bar: the user's clock, both appearances and all three device
        // states at 1x/2x/3x. The names are the ones `NSImage(named:)`
        // resolves from loose files in `Contents/Resources` — the 1x file
        // carries no scale suffix, the @2x and @3x do. `empty` is the
        // no-clock screen: the `AppGlyph.emptyDrawing` table names it.
        for (scale, suffix) in [(1, ""), (2, "@2x"), (3, "@3x")] {
            for (appearance, online, offline, empty) in [
                ("dark", UserClock.darkOnline, UserClock.darkOffline,
                 UserClock.empty(UserClock.darkOnline)),
                ("light", UserClock.lightOnline, UserClock.lightOffline,
                 UserClock.empty(UserClock.lightOnline)),
            ] {
                write(renderClock(online, scale: scale), to: "\(out)/userclock-\(appearance)-online\(suffix).png")
                write(renderClock(offline, scale: scale), to: "\(out)/userclock-\(appearance)-offline\(suffix).png")
                write(renderClock(empty, scale: scale), to: "\(out)/userclock-\(appearance)-empty\(suffix).png")
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
        write(drawUserClockContext(), to: "\(out)/preview-menubar-context.png")
        write(drawUserClockZoom(), to: "\(out)/preview-menubar-zoom.png")
        write(drawSmallComparison(), to: "\(out)/preview-small-comparison.png")

        print("wrote \(out)")
    }
}
