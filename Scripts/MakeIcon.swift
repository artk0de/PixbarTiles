// swiftc Sources/PixelClockTilesApp/MenuBarUserclock.swift Scripts/MakeIcon.swift -o build/icon-maker && build/icon-maker
//
// Renders the app icon set and the menu bar glyph from code.
//
//     Scripts/bundle.sh            # compiles and runs this as part of bundling
//
// The app icon exists because AWTRIX 3 ships no square logo — only a wide
// AI-rendered cover banner whose wordmark is illegible below about 64pt, and
// which is CC BY-NC-SA. So the mark is drawn rather than borrowed: it is the
// thing AWTRIX actually is, a Ulanzi slab with a 32x8 LED matrix across its
// face.
//
// The menu bar glyph is the user's own pixel-art clock, transcribed and
// approved out of icons-candidates/menubar as the userclock variants. Its map
// lives in `Sources/PixelClockTilesApp/MenuBarUserclock.swift` — the file is
// compiled into this tool AND into the app target, so the PNGs the bundle
// ships are rasterized from the very map the tests pin, and the two cannot
// drift apart. Top-level statements live in `MakeIcon.main` because a
// multi-file compile only reads them from `main.swift`.
//
// Deterministic by construction: two runs produce byte-identical art, and a
// diff means someone changed the design.

import AppKit

let COLS = 32
let ROWS = 8

/// The cover art's palette, sampled by eye: saturated LED primaries on black.
let PALETTE: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.16, blue: 0.18, alpha: 1),  // red
    NSColor(srgbRed: 1.00, green: 0.52, blue: 0.06, alpha: 1),  // amber
    NSColor(srgbRed: 1.00, green: 0.84, blue: 0.10, alpha: 1),  // yellow
    NSColor(srgbRed: 0.22, green: 0.92, blue: 0.35, alpha: 1),  // green
    NSColor(srgbRed: 0.15, green: 0.85, blue: 0.95, alpha: 1),  // cyan
    NSColor(srgbRed: 0.28, green: 0.48, blue: 1.00, alpha: 1),  // blue
    NSColor(srgbRed: 0.85, green: 0.35, blue: 1.00, alpha: 1),  // magenta
]

/// Integer hash — deterministic stand-in for randomness, since the icon must
/// render identically on every machine and in every future run.
func noise(_ x: Int, _ y: Int, _ salt: Int) -> Int {
    var h = x &* 374_761_393 &+ y &* 668_265_263 &+ salt &* 2_246_822_519
    h = (h ^ (h >> 13)) &* 1_274_126_177
    return abs(h ^ (h >> 16))
}

/// A 7-row pixel font, six glyphs — exactly the six the mark needs. Widths vary
/// because the diagonals decide them: W and X need five columns to read as
/// themselves rather than as a blob and an hourglass, while I is better at
/// three, where its stem lands dead centre. 4+5+4+4+3+5 glyph columns plus five
/// single-column gaps is 30, leaving one column of margin at each end of the
/// 32-column panel. Change any width and the wordmark stops fitting the real
/// hardware's geometry.
let GLYPHS: [[String]] = [
    [".##.", "#..#", "#..#", "####", "#..#", "#..#", "#..#"],          // A
    ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],   // W
    ["####", ".#..", ".#..", ".#..", ".#..", ".#..", ".#.."],          // T
    ["###.", "#..#", "#..#", "###.", "#.#.", "#..#", "#..#"],          // R
    ["###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"],                 // I
    ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],   // X
]

/// Which palette colour lights each letter. Distinct hues are decoration only
/// here — the single-column gaps are what actually separates the letters.
let LETTER_COLOUR = [0, 2, 3, 4, 5, 6]

/// Left edge of each glyph, laid out once: one column of margin, then each
/// glyph followed by a single-column gap.
let LETTER_ORIGIN: [Int] = {
    var origins: [Int] = []
    var x = 1
    for glyph in GLYPHS {
        origins.append(x)
        x += glyph[0].count + 1
    }
    return origins
}()

/// Lit cell -> its colour, or nil when the cell stays dark. Row 0 is the top of
/// the panel; the wordmark occupies rows 0...6 of 8, so the spare row sits at
/// the bottom where it reads as clearance rather than a crop.
func wordmarkColour(col: Int, row: Int) -> NSColor? {
    guard row >= 0, row < 7 else { return nil }
    for (index, glyph) in GLYPHS.enumerated() {
        let x = col - LETTER_ORIGIN[index]
        guard x >= 0, x < glyph[0].count else { continue }
        guard Array(glyph[row])[x] == "#" else { return nil }
        return PALETTE[LETTER_COLOUR[index]]
    }
    return nil
}

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

/// The four variants where they will live: a light and a dark menu bar, each
/// with its appearance's glyph online and offline, at true 2x. The view a human
/// eyeballs without opening twelve PNG files — the same role the drawn
/// candidates' comparison sheet played when the design was being chosen.
func drawUserClockContext() -> CGContext {
    let scale = 2, pt = 18 * scale, barHeight = 24 * scale, width = 200 * scale
    let ctx = makeContext(width)
    ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: width))

    let bars: [(NSColor, UserClock.Palette, UserClock.Palette, CGFloat)] = [
        (colour(0xF2F2F2), UserClock.lightOnline, UserClock.lightOffline,
         CGFloat(width - barHeight)),
        (colour(0x212121), UserClock.darkOnline, UserClock.darkOffline,
         CGFloat(width - barHeight * 3)),
    ]
    for (background, online, offline, y) in bars {
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(barHeight)))
        let inset = CGFloat(barHeight - pt) / 2
        for (index, palette) in [online, offline].enumerated() {
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
    let ctx = makeContext(margin + (wide + margin) * 4, high + margin * 2)
    ctx.setFillColor(colour(0xE8E8EA).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.interpolationQuality = .none
    for (index, palette) in [UserClock.lightOnline, UserClock.lightOffline,
                             UserClock.darkOnline, UserClock.darkOffline].enumerated() {
        let x = margin + (wide + margin) * index
        ctx.draw(renderClock(palette, scale: 1),
                 in: CGRect(x: x, y: margin, width: wide, height: high))
    }
    return ctx
}

// MARK: - The app icon

/// The app icon: the device seen head-on. Body fills the Big Sur content square
/// (824/1024 of the canvas), the matrix band sits across its middle.
func drawAppIcon(size: Int) -> CGContext {
    let ctx = makeContext(size)
    let s = CGFloat(size)
    let inset = s * 0.098                      // Big Sur content inset
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237           // squircle-ish corner

    // Slab: a near-black body with a faint top-down sheen, so the icon reads as
    // an object rather than a flat tile.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            NSColor(srgbRed: 0.13, green: 0.13, blue: 0.16, alpha: 1).cgColor,
            NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: []
    )
    ctx.restoreGState()

    // Matrix band — 4:1, the real panel's aspect.
    let bandWidth = body.width * 0.84
    let cell = bandWidth / CGFloat(COLS)
    let bandHeight = cell * CGFloat(ROWS)
    let band = CGRect(
        x: body.midX - bandWidth / 2, y: body.midY - bandHeight / 2,
        width: bandWidth, height: bandHeight
    )

    let glass = band.insetBy(dx: -cell * 0.6, dy: -cell * 0.6)
    ctx.setFillColor(NSColor(srgbRed: 0.01, green: 0.01, blue: 0.02, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: glass, cornerWidth: cell * 0.7, cornerHeight: cell * 0.7, transform: nil))
    ctx.fillPath()

    // Every cell is drawn: unlit ones as a dim dot, so the panel keeps its grid
    // texture instead of looking like scattered confetti on black.
    let dot = cell * 0.34
    for col in 0..<COLS {
        for row in 0..<ROWS {
            let cx = band.minX + (CGFloat(col) + 0.5) * cell
            let cy = band.minY + (CGFloat(row) + 0.5) * cell
            let rect = CGRect(x: cx - dot, y: cy - dot, width: dot * 2, height: dot * 2)

            // The panel shows what the device itself would show: the AWTRIX
            // wordmark. Everything else stays an unlit dot so the grid reads as
            // a matrix rather than as floating confetti.
            guard let base = wordmarkColour(col: col, row: ROWS - 1 - row) else {
                ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
                ctx.fillEllipse(in: rect)
                continue
            }
            let brightness = 0.55 + CGFloat(noise(col, row, 11) % 25) / 100

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: cell * 0.9, color: base.withAlphaComponent(0.9).cgColor)
            ctx.setFillColor(base.highlight(withLevel: brightness * 0.35)!.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
        }
    }
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
        // wordmark survives legibly to 32px, where art drawn directly at that size
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

        // Menu bar: the user's clock, both appearances and both device states at
        // 1x/2x/3x. The names are the ones `NSImage(named:)` resolves from loose
        // files in `Contents/Resources` — the 1x file carries no scale suffix,
        // the @2x and @3x do.
        for (scale, suffix) in [(1, ""), (2, "@2x"), (3, "@3x")] {
            for (appearance, online, offline) in [
                ("dark", UserClock.darkOnline, UserClock.darkOffline),
                ("light", UserClock.lightOnline, UserClock.lightOffline),
            ] {
                write(renderClock(online, scale: scale), to: "\(out)/userclock-\(appearance)-online\(suffix).png")
                write(renderClock(offline, scale: scale), to: "\(out)/userclock-\(appearance)-offline\(suffix).png")
            }
        }

        // Previews, purely so a human can eyeball the result without opening ten
        // files: the detailed app icon, the menu bar variants on the bars
        // themselves and magnified with interpolation off.
        write(drawAppIcon(size: 512).makeImage()!, to: "\(out)/preview-detailed.png")
        write(drawUserClockContext(), to: "\(out)/preview-menubar-context.png")
        write(drawUserClockZoom(), to: "\(out)/preview-menubar-zoom.png")
        write(drawSmallComparison(), to: "\(out)/preview-small-comparison.png")

        print("wrote \(out)")
    }
}
