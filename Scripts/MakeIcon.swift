#!/usr/bin/env swift
// Renders the app icon set and the menu bar glyph from code.
//
// AWTRIX 3 ships no square logo — only a wide AI-rendered cover banner whose
// wordmark is illegible below about 64pt, and which is CC BY-NC-SA. So the mark
// here is drawn rather than borrowed: it is the thing AWTRIX actually is, a
// Ulanzi slab with a 32x8 LED matrix across its face.
//
//     swift Scripts/MakeIcon.swift            # writes build/icon/
//
// Deterministic by construction: every lit pixel comes from a hash of its own
// coordinates, so two runs produce byte-identical art and a diff means someone
// changed the design.

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
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

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

/// The menu bar glyph: a template image, so macOS recolours it for light, dark
/// and the highlighted state. Template means shape only — colour is discarded,
/// so the matrix has to read as a silhouette at 18pt.
/// Menu bar styles under consideration. The panel is 4:1 like the real one, so
/// in an 18pt square it is wide and short — which is most of what makes it
/// recognisable at this size.
/// The style the app actually ships. The rest stay in the file because the
/// comparison sheet is what settled the choice, and a future change should be
/// made by rendering them again rather than by argument.
let SHIPPED_STYLE = GlyphStyle.device

enum GlyphStyle: String, CaseIterable {
    case pixels    // solid panel, pixels knocked out of it
    case device    // the body, with a display knocked out of it and lit pixels inside
    case slab      // solid panel, nothing on it
    case blocks    // solid panel, three large blocks knocked out
}

/// `lit` carries the device state. Offline is drawn as the same panel outlined
/// rather than filled: an unlit screen, which is what an unreachable clock
/// actually looks like, and a difference that survives being 18pt.
func drawMenuBarGlyph(size: Int, lit: Bool = true, style: GlyphStyle = SHIPPED_STYLE) -> CGContext {
    // The menu bar accepts a template image wider than it is tall, and the
    // panel is 4:1 — squeezed into an 18pt square it would be 17x5pt, most of
    // the box wasted on empty air. A 26x18 canvas gives the same glyph half
    // again as much ink at the same bar height.
    // The device style needs more width: it carries a body AND a screen, where
    // the others carry only the panel.
    let box = Int((CGFloat(size) * (style == .device ? 30 : 26) / 18).rounded())
    let ctx = makeContext(box, size)
    let s = CGFloat(size)

    let width = CGFloat(box) * 0.94
    let height = width / 3.4
    let panel = CGRect(x: (CGFloat(box) - width) / 2, y: (s - height) / 2, width: width, height: height)
    // Deliberately shallow. A 4:1 rounded pill in a menu bar reads as the
    // battery indicator sitting a few points away; a squarer panel does not.
    let corner = height * 0.16
    let path = CGPath(roundedRect: panel, cornerWidth: corner, cornerHeight: corner, transform: nil)

    guard lit || style == .device else {
        // Outline only. The stroke is rounded to whole pixels because a
        // half-pixel line at this size renders as grey mush.
        let line = max(1, (s * 0.075).rounded())
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(line)
        ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: line / 2, dy: line / 2),
                           cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.strokePath()
        return ctx
    }

    if style == .device {
        // Body first, then the screen cleared out of it, then the lit pixels
        // put back inside the screen. Three steps, because a display is a hole
        // in a thing rather than a thing next to it.
        let body = CGRect(x: 0, y: (s - s * 0.84) / 2, width: CGFloat(box), height: s * 0.84)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: body.height * 0.24,
                           cornerHeight: body.height * 0.24, transform: nil))
        ctx.fillPath()

        // Bezel proportions taken from the hardware: a thin frame around a screen
        // that occupies most of the face. An earlier pass made the frame thicker
        // than the display it framed, which read as a brick.
        let screen = body.insetBy(dx: body.height * 0.12, dy: body.height * 0.19)
        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screen.height * 0.16,
                           cornerHeight: screen.height * 0.16, transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.normal)

        guard lit else { return ctx }
        ctx.setFillColor(NSColor.black.cgColor)
        let cols = 6, rows = 2
        let grid = screen.insetBy(dx: screen.height * 0.16, dy: screen.height * 0.16)
        let cw = grid.width / CGFloat(cols)
        let ch = grid.height / CGFloat(rows)
        let side = min(cw, ch) * 0.7
        for col in 0..<cols {
            for row in 0..<rows {
                let cx = grid.minX + (CGFloat(col) + 0.5) * cw
                let cy = grid.minY + (CGFloat(row) + 0.5) * ch
                ctx.fill(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
            }
        }
        return ctx
    }

    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(path)
    ctx.fillPath()

    // Knockouts: clearing pixels out of a filled panel keeps the silhouette
    // whole, where drawing marks on top of it would break the shape apart.
    ctx.setBlendMode(.clear)
    switch style {
    case .device:
        break  // returned above; it draws body, screen and pixels itself
    case .slab:
        break
    case .pixels:
        let cols = 6, rows = 2
        let inner = panel.insetBy(dx: height * 0.22, dy: height * 0.22)
        let cw = inner.width / CGFloat(cols)
        let ch = inner.height / CGFloat(rows)
        let side = min(cw, ch) * 0.55
        for col in 0..<cols {
            for row in 0..<rows {
                let cx = inner.minX + (CGFloat(col) + 0.5) * cw
                let cy = inner.minY + (CGFloat(row) + 0.5) * ch
                ctx.fill(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
            }
        }
    case .blocks:
        let inner = panel.insetBy(dx: height * 0.26, dy: height * 0.26)
        let gap = inner.width * 0.09
        let bw = (inner.width - gap * 2) / 3
        for index in 0..<3 {
            ctx.fill(CGRect(x: inner.minX + (bw + gap) * CGFloat(index), y: inner.minY,
                            width: bw, height: inner.height))
        }
    }
    return ctx
}

/// A template image is drawn by macOS in one colour, chosen by the menu bar's
/// appearance and by whether the item is highlighted. Recolouring here on a
/// separate transparent surface reproduces that, rather than approximating it —
/// compositing the tint straight onto the bar would flood the whole cell.
func tinted(_ glyph: CGContext, _ colour: NSColor) -> CGImage {
    let out = makeContext(glyph.width)
    let rect = CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height)
    out.draw(glyph.makeImage()!, in: rect)
    out.setBlendMode(.sourceIn)
    out.setFillColor(colour.cgColor)
    out.fill(rect)
    return out.makeImage()!
}

/// The glyph as it will actually appear: true 18pt, at 2x, on both menu bar
/// appearances, in both device states. Every earlier preview magnified it,
/// which is exactly the view that cannot answer "is this legible".
func drawStyleSheet() -> CGContext {
    let size = 460
    let ctx = makeContext(size)
    ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let pt = 36                       // 18pt at 2x — one true menu bar item
    let barHeight = 48
    var y = size - 70
    for style in GlyphStyle.allCases {
        for (background, ink) in [(NSColor(white: 0.96, alpha: 1), NSColor.black),
                                  (NSColor(white: 0.11, alpha: 1), NSColor.white)] {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(size), height: CGFloat(barHeight)))
            let inset = CGFloat(barHeight - pt) / 2
            for (index, lit) in [true, false].enumerated() {
                let wide = CGFloat(pt) * (style == .device ? 30 : 26) / 18
                ctx.draw(
                    tinted(drawMenuBarGlyph(size: pt, lit: lit, style: style), ink),
                    in: CGRect(x: CGFloat(size) - (wide + 24) * CGFloat(index + 1),
                               y: CGFloat(y) + inset, width: wide, height: CGFloat(pt))
                )
            }
            // The same pair magnified, so shape and true legibility sit side by side.
            ctx.interpolationQuality = .none
            for (index, lit) in [true, false].enumerated() {
                ctx.draw(
                    tinted(drawMenuBarGlyph(size: 18, lit: lit, style: style), ink),
                    in: CGRect(x: CGFloat(12 + index * 80), y: CGFloat(y) + 2,
                               width: CGFloat(style == .device ? 73 : 64), height: 44)
                )
            }
            y -= barHeight + 4
        }
        y -= 14
    }
    return ctx
}

func drawMenuBarContext() -> CGContext {
    let scale = 2, pt = 18 * scale, barHeight = 24 * scale, width = 200 * scale
    let ctx = makeContext(width)
    ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: width))

    let bars: [(NSColor, NSColor, CGFloat)] = [
        (NSColor(white: 0.96, alpha: 1), .black, CGFloat(width - barHeight)),   // light
        (NSColor(white: 0.11, alpha: 1), .white, CGFloat(width - barHeight * 3)), // dark
    ]
    for (background, ink, y) in bars {
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(barHeight)))
        let inset = CGFloat(barHeight - pt) / 2
        let wide = CGFloat(pt) * 26 / 18
        for (index, lit) in [true, false].enumerated() {
            let x = CGFloat(width) - (wide + CGFloat(barHeight) / 2) * CGFloat(index + 1)
            ctx.draw(
                tinted(drawMenuBarGlyph(size: pt, lit: lit), ink),
                in: CGRect(x: x, y: y + inset, width: wide, height: CGFloat(pt))
            )
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

// Menu bar: 18pt at 1x/2x/3x, each in both device states.
for (scale, suffix) in [(1, ""), (2, "@2x"), (3, "@3x")] {
    write(drawMenuBarGlyph(size: 18 * scale), to: "\(out)/MenuBarIcon\(suffix).png")
    write(drawMenuBarGlyph(size: 18 * scale, lit: false), to: "\(out)/MenuBarIconOffline\(suffix).png")
}

// Previews, purely so a human can eyeball the result without opening ten files:
// the detailed art, the small-size art, and the menu bar glyph magnified with
// interpolation off so its actual pixels are visible.
write(drawAppIcon(size: 512), to: "\(out)/preview-detailed.png")

let zoom = makeContext(180)
zoom.interpolationQuality = .none
zoom.setFillColor(NSColor.white.cgColor)
zoom.fill(CGRect(x: 0, y: 0, width: 180, height: 180))
// Both states side by side, each kept square — a stretched preview would
// misrepresent the glyph it is supposed to be checking.
zoom.draw(drawMenuBarGlyph(size: 18).makeImage()!, in: CGRect(x: 0, y: 59, width: 90, height: 62))
zoom.draw(drawMenuBarGlyph(size: 18, lit: false).makeImage()!, in: CGRect(x: 90, y: 59, width: 90, height: 62))
write(zoom, to: "\(out)/preview-menubar.png")
write(drawMenuBarContext(), to: "\(out)/preview-menubar-context.png")
write(drawStyleSheet(), to: "\(out)/preview-menubar-styles.png")
write(drawSmallComparison(), to: "\(out)/preview-small-comparison.png")

print("wrote \(out)")
