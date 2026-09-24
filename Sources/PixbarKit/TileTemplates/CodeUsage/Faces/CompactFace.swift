import Foundation

/// The TC002 usage face Claude and z.ai share: the vendor's mark, a session
/// row and a weekly row — label, figure, and a one-pixel bar under each — and,
/// for a row at or past the tile's "show reset after", a second phase naming
/// when that window starts again.
///
/// The design was approved as the frames the `tc002-face-mockup` skill's
/// `gen.py` computes, in the browser and on the clock; `UsageFaceOracleTests`
/// holds this type to those frames pixel for pixel and delay for delay. Every
/// constant here is gen.py's, and a change of design starts THERE.
///
/// The page is one timeline played by the panel itself — one full-frame GIF,
/// each frame with its own delay — so the Mac pushes once per poll and never
/// re-pushes for motion:
///
/// - Frame A, the percentages, stands for "show reset every".
/// - A hot `5h` row flips to `rst HH:mm` — 31 columns against its 32, so it
///   stands still, centred in what the row has left. With only `5h` hot, that
///   is one frame of five seconds.
/// - A hot `week` row's `rst d mmm HH:mm` is 55 columns against its 31, so it
///   makes one pass: in past the panel's right edge, out past the row's left
///   boundary, a pixel every 60 ms. A hot `5h` shows its reset, still, in
///   every one of those frames.
///
/// Reset times are INSTANTS, said in the zone the face is drawn in — the
/// Mac's — whatever zone the vendor's server keeps (z.ai's is Asia/Shanghai).
public extension CodeUsage {
    enum Compact {
        // MARK: - Layout (gen.py's constants)

        private static let logoOrigin = PixelPoint(x: 0, y: 1)
        /// Where each row's label starts.
        ///
        /// The mark is five rows tall and stands on the TOP row alone, so the top
        /// label begins after it and the bottom one at the panel's edge. Nine
        /// columns of the weekly row were being held for a mark that is not there
        /// — and they are exactly the columns its long reset was scrolling for.
        private static let labelX = [9, 0]
        /// Columns between a label and the value area. Fewer, and a scrolling
        /// value reads as one word with its label.
        private static let labelGap = 4
        /// The rows are named for the PERIOD each measures.
        ///
        /// `s` and `w` were one glyph apiece because the face was built before
        /// there was anything else to call them, and a single letter is a legend
        /// the panel never prints.
        private static let rows: [(label: String, top: Int)] = [("5h", 1), ("week", 9)]

        /// How long a reset that fits its row stands.
        private static let dwellMilliseconds = 5_000
        /// One pixel a frame, the whole pass at one speed.
        private static let marqueeStepMilliseconds = 60

        private static let font = PixelFont.proportional

        // MARK: - The timeline

        /// The page as the panel plays it: frame A, then the reset phase for the
        /// rows `config` calls hot. A row is hot when it has a reading at or past
        /// `resetAfter` AND a reset date — a hot row whose source named no reset
        /// has nothing to flip to, and the page stays the percentages rather than
        /// inventing a time.
        public static func timeline(
            vendor: Vendor, session: Window?, weekly: Window?,
            config: CodeUsage.Parameters, timeZone: TimeZone
        ) -> [Frame] {
            let windows = [session, weekly]
            let hot = windows.map { window in
                guard let window, window.resetsAt != nil else { return false }
                return window.percent >= config.resetAfter
            }
            let percents = windows.map { $0.map { CodeUsage.percentText($0.percent) } ?? "--" }
            let phase = percentPhase(
                vendor, windows,
                values: percents.map { (text: $0, x: nil) },
                milliseconds: Int((config.resetEvery * 1000).rounded())
            )
            guard hot.contains(true) else { return phase }

            let messages = [
                session?.resetsAt.map { CodeUsage.sessionReset($0, in: timeZone) },
                weekly?.resetsAt.map {
                    CodeUsage.weeklyReset($0, in: timeZone, order: config.dateOrder)
                },
            ]
            let fits = messages.indices.map { index in
                guard let message = messages[index] else { return false }
                return font.width(of: message, scale: 1) <= valueArea(index).count
            }

            // Everything that fits is placed first, CENTRED in what its row has
            // left — for those seconds the reset is the whole content of the row,
            // and inheriting the figure's right alignment leaves a gap exactly
            // where the eye starts reading. A row that must scroll then scrolls
            // with the other row's reset already standing beside it.
            let values: [(text: String, x: Int?)] = messages.indices.map { index in
                guard hot[index], fits[index], let message = messages[index] else {
                    return (percents[index], nil)
                }
                let area = valueArea(index)
                let x = area.lowerBound + (area.count - font.width(of: message, scale: 1)) / 2
                return (message, x)
            }
            let scrolling = messages.indices.filter { hot[$0] && !fits[$0] }
            guard !scrolling.isEmpty else {
                let flipped = draw(vendor, windows, values: values)
                return phase + [Frame(canvas: flipped, milliseconds: dwellMilliseconds)]
            }

            var frames = phase
            for index in scrolling {
                guard let message = messages[index] else { continue }
                let width = font.width(of: message, scale: 1)
                let area = valueArea(index)
                for x in stride(from: PixelCanvas.width, through: area.lowerBound - width, by: -1) {
                    var shown = values
                    shown[index] = (message, x)
                    frames.append(Frame(
                        canvas: draw(vendor, windows, values: shown),
                        milliseconds: marqueeStepMilliseconds
                    ))
                }
            }
            return frames
        }

        /// One beat of the spent pulse.
        private static let pulseMilliseconds = 420
        /// How many beats it breathes before it holds.
        ///
        /// A pulse that never stops stops being read — the same reason the ramp
        /// starts as late as it does — and a long "show reset every" would
        /// otherwise spend the panel's whole frame budget on one blinking row.
        private static let pulseFrames = 24

        /// Frame A: one still frame, or the spent pulse when a window is full.
        ///
        /// The pulse is the percent phase's alone. A row showing its reset is
        /// being read as TEXT — the session's still, the week's gliding a pixel a
        /// frame — and text that blinks under the eye is text nobody finishes.
        private static func percentPhase(
            _ vendor: Vendor, _ windows: [Window?], values: [(text: String, x: Int?)],
            milliseconds: Int
        ) -> [Frame] {
            let spent = windows.contains { $0.map { CodeUsage.Band(utilization: $0.percent) == .spent } ?? false }
            guard spent else {
                return [Frame(canvas: draw(vendor, windows, values: values), milliseconds: milliseconds)]
            }
            let bright = draw(vendor, windows, values: values)
            let dark = draw(vendor, windows, values: values, dim: true)
            // Floor, so the beats plus the rest come to exactly the interval asked
            // for rather than overrunning it by part of a beat.
            let beats = min(pulseFrames, max(2, milliseconds / pulseMilliseconds))
            var frames = (0..<beats).map { beat in
                Frame(
                    canvas: beat.isMultiple(of: 2) ? bright : dark,
                    milliseconds: pulseMilliseconds
                )
            }
            let rest = milliseconds - pulseMilliseconds * beats
            if rest > 0 { frames.append(Frame(canvas: bright, milliseconds: rest)) }
            return frames
        }

        /// This face's timeline as the page the TC002 plays by itself.
        ///
        /// The envelope — the full-frame GIF, the per-frame delays, the
        /// fallback when encoding fails — belongs to the template and is the
        /// same for every face it carries; this hands its frames over.
        public static func delivery(
            vendor: Vendor, session: Window?, weekly: Window?,
            config: CodeUsage.Parameters, timeZone: TimeZone
        ) -> UlanziDelivery {
            Tile.page(timeline(
                vendor: vendor, session: session, weekly: weekly,
                config: config, timeZone: timeZone
            ))
        }

        // MARK: - One picture

        /// The columns a row's value may use: after its OWN label, plus the gap,
        /// to the panel's edge.
        ///
        /// Per row rather than one box as wide as the widest name. That box was
        /// written for one-letter labels, where it kept the two marks from hanging
        /// off one another; with two words of different lengths it only takes the
        /// shorter row's columns away and gives nothing back.
        private static func valueArea(_ index: Int) -> Range<Int> {
            let start = labelX[index] + font.width(of: rows[index].label, scale: 1) + labelGap
            return start..<PixelCanvas.width
        }

        /// One frame: the mark, and per row its label, its value — right-aligned
        /// when `x` is nil, clipped to the row's value area either way — and its
        /// bar.
        private static func draw(
            _ vendor: Vendor, _ windows: [Window?], values: [(text: String, x: Int?)],
            dim: Bool = false
        ) -> PixelCanvas {
            var canvas = PixelCanvas()
            let logoInk = Pixel(colour: vendor.logoColour)
            for (dy, row) in vendor.logo.enumerated() {
                for (dx, mark) in row.enumerated() where mark == "#" {
                    canvas[logoOrigin.x + dx, logoOrigin.y + dy] = logoInk
                }
            }
            for (index, ((label, top), (window, value)))
                in zip(rows, zip(windows, values)).enumerated()
            {
                canvas.drawText(
                    label, at: PixelPoint(x: labelX[index], y: top),
                    ink: Pixel(colour: CodeUsage.labelColour), font: font
                )
                // The value on a strip as wide as its area, laid on the page: the
                // strip's edge is the clip, so a scrolling reset never reaches
                // the label.
                let area = valueArea(index)
                var strip = PixelCanvas(width: area.count, height: font.height)
                let x = value.x ?? PixelCanvas.width - font.width(of: value.text, scale: 1)
                strip.drawText(
                    value.text, at: PixelPoint(x: x - area.lowerBound, y: 0),
                    ink: Pixel(colour: CodeUsage.figureColour(vendor, at: window?.percent, dim: dim)), font: font
                )
                canvas.draw(strip, at: PixelPoint(x: area.lowerBound, y: top))

                let barY = top + 6
                canvas.drawRect(
                    PixelRect(x: 0, y: barY, width: PixelCanvas.width, height: 1),
                    color: Pixel(colour: CodeUsage.trackColour)
                )
                if let window, window.percent > 0 {
                    let filled = max(1, (PixelCanvas.width * min(window.percent, 100) + 50) / 100)
                    canvas.drawRect(
                        PixelRect(x: 0, y: barY, width: filled, height: 1),
                        color: Pixel(colour: CodeUsage.fillColour(at: window.percent, dim: dim))
                    )
                }
            }
            return canvas
        }
    }
}
