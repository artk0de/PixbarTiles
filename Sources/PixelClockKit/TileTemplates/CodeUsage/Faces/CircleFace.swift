import Foundation

public extension CodeUsage {
    /// The TC002 face that shows ONE window at a time, with the reading drawn
    /// around the panel's edge.
    ///
    /// Compact answers "where do both windows stand" in one glance and pays for
    /// it in size: two rows of 5×5 on a panel sixteen pixels tall leave the
    /// figure the same height as its label. Circle answers "where does THIS
    /// window stand" and spends the whole panel on it — the reading at 5×9, and
    /// the gauge unrolled around the rim, where it is 132 cells instead of 52
    /// and one cell is under a percent.
    ///
    /// The rim is a frame, not a fourth row: it costs no interior pixels, and a
    /// reader who is not looking for it sees a panel with a coloured border
    /// rather than a chart they have to decode.
    ///
    /// The design was approved as the frames the `tc002-face-mockup` skill's
    /// `gen.py` computes, in the browser and on the clock; `UsageCircleOracle
    /// Tests` holds this type to those frames pixel for pixel and delay for
    /// delay. Every constant here is gen.py's, and a change of design starts
    /// THERE.
    enum Circle {
        // MARK: - Layout (gen.py's constants)

        /// The mark's corner. Everything the rim frames starts after it.
        private static let markOrigin = PixelPoint(x: 2, y: 2)
        /// Where the window's name sits, along the bottom.
        private static let nameY = 9
        private static let figureTop = 3
        /// The figure's right edge — one column of air inside the rim.
        private static let figureRight = PixelCanvas.width - 3
        private static let resetTop = 4
        /// The eight-wide mark at x2, and a column of air.
        private static let resetLeft = 11

        /// What the dwell spends on a reset once a window is hot. The reading is
        /// the headline and keeps the larger share of every turn.
        private static let resetShare = 0.4
        /// One pixel a frame, the whole pass at one speed.
        private static let marqueeStepMilliseconds = 60
        private static let pulseMilliseconds = 420
        private static let pulseFrames = 24
        /// The change of window, as one continuous move.
        private static let sweepMilliseconds = 45
        private static let sweepSteps = 12

        private static let font = PixelFont.proportional
        /// The reading itself, at nine rows — the whole point of spending the
        /// panel on one window.
        private static let figureFont = PixelFont.big

        /// The perimeter, clockwise from the top-left, each cell exactly once.
        ///
        /// Clockwise from the corner rather than from the bottom, because a
        /// gauge is read the way a clock is and the panel has no other zero to
        /// start from. Each corner belongs to the run that reaches it first, so
        /// no cell is drawn — or counted — twice.
        static let rim: [PixelPoint] = {
            let width = PixelCanvas.width
            let height = PixelCanvas.height
            var path = (0..<width).map { PixelPoint(x: $0, y: 0) }
            path += (1..<height).map { PixelPoint(x: width - 1, y: $0) }
            path += stride(from: width - 2, through: 0, by: -1)
                .map { PixelPoint(x: $0, y: height - 1) }
            path += stride(from: height - 2, through: 1, by: -1)
                .map { PixelPoint(x: 0, y: $0) }
            return path
        }()

        /// Cells of the rim a reading fills.
        ///
        /// A reading that exists is never zero cells: one percent has to look
        /// different from no data at all, and at 132 cells it rounds to one
        /// either way.
        static func litCells(_ percent: Int?) -> Int {
            guard let percent, percent > 0 else { return 0 }
            let filled = Double(rim.count) * Double(min(percent, 100)) / 100
            return max(1, Int(filled.rounded(.toNearestOrEven)))
        }

        // MARK: - The timeline

        /// The page as the panel plays it: every selected window in turn, each
        /// arrived at by a count.
        ///
        /// `windows` is what the tile's multi-select produces, in the order they
        /// are shown. One window selected is one turn and no transition at all,
        /// because there is nothing to change to.
        public static func timeline(
            vendor: Vendor, windows: [(kind: WindowKind, reading: Window?)],
            parameters: Parameters, timeZone: TimeZone
        ) -> [Frame] {
            let dwell = Int(parameters.resetEvery * 1000)
            guard windows.count > 1 else {
                guard let only = windows.first else { return [] }
                return turn(
                    vendor: vendor, kind: only.kind, reading: only.reading,
                    dwell: dwell, after: parameters.resetAfter,
                    timeZone: timeZone, order: parameters.dateOrder
                )
            }
            var frames: [Frame] = []
            for (index, window) in windows.enumerated() {
                let previous = windows[(index + windows.count - 1) % windows.count]
                frames += sweep(
                    vendor: vendor, from: previous.reading?.percent,
                    kind: window.kind, to: window.reading?.percent
                )
                frames += turn(
                    vendor: vendor, kind: window.kind, reading: window.reading,
                    dwell: dwell, after: parameters.resetAfter,
                    timeZone: timeZone, order: parameters.dateOrder
                )
            }
            return frames
        }

        /// The gauge re-measuring in one move: the rim runs from where it WAS to
        /// where it belongs while the figure counts with it.
        ///
        /// Counting is what makes this read as one instrument re-measuring
        /// rather than as two pages. A rim that slides under a figure that
        /// jumped is a rim catching up — the eye follows the digits, and the
        /// motion it was given happens somewhere it is not looking. The name
        /// changes on the first step, so from then on everything drawn is about
        /// the window being arrived at.
        ///
        /// Drawn AT the blended reading rather than with a blended rim under a
        /// settled figure: one number drives the rim, the digits and the band's
        /// colour together, so the three cannot disagree for a frame.
        ///
        /// A window with no reading has nothing to count to — it cuts, and the
        /// cut is honest: there is no value between 41% and "--".
        private static func sweep(
            vendor: Vendor, from previous: Int?, kind: WindowKind, to percent: Int?
        ) -> [Frame] {
            guard let previous, let percent else {
                return [Frame(
                    canvas: draw(vendor, kind: kind, percent: percent),
                    milliseconds: sweepMilliseconds * 3
                )]
            }
            let start = Double(min(previous, 100))
            let end = Double(min(percent, 100))
            return (1...sweepSteps).map { step in
                let blended = start + (end - start) * Double(step) / Double(sweepSteps)
                return Frame(
                    canvas: draw(
                        vendor, kind: kind, percent: Int(blended.rounded(.toNearestOrEven))
                    ),
                    milliseconds: sweepMilliseconds
                )
            }
        }

        /// One window's turn on the panel: its reading, then its reset when it
        /// has one and is past the threshold.
        private static func turn(
            vendor: Vendor, kind: WindowKind, reading: Window?,
            dwell: Int, after: Int, timeZone: TimeZone, order: CodeUsage.DateOrder
        ) -> [Frame] {
            let percent = reading?.percent
            let resetsAt = reading?.resetsAt
            let hot = percent.map { $0 >= after } == true && resetsAt != nil
            let readingMilliseconds = hot ? Int(Double(dwell) * (1 - resetShare)) : dwell

            var frames = readingFrames(
                vendor, kind: kind, percent: percent, for: readingMilliseconds
            )
            guard hot, let resetsAt else { return frames }
            frames += resetFrames(
                vendor: vendor, kind: kind, percent: percent,
                message: kind.reset(resetsAt, in: timeZone, order: order),
                milliseconds: dwell - readingMilliseconds
            )
            return frames
        }

        /// The reading itself: one still frame, or the spent pulse when the
        /// bucket is full.
        private static func readingFrames(
            _ vendor: Vendor, kind: WindowKind, percent: Int?, for milliseconds: Int
        ) -> [Frame] {
            guard let percent, Band(utilization: percent) == .spent else {
                return [Frame(
                    canvas: draw(vendor, kind: kind, percent: percent),
                    milliseconds: milliseconds
                )]
            }
            let bright = draw(vendor, kind: kind, percent: percent)
            let dark = draw(vendor, kind: kind, percent: percent, dim: true)
            // Floor, so the beats plus the rest come to exactly the interval
            // asked for rather than overrunning it by part of a beat.
            let beats = min(pulseFrames, max(2, milliseconds / pulseMilliseconds))
            var frames = (0..<beats).map { beat in
                Frame(canvas: beat % 2 == 0 ? bright : dark, milliseconds: pulseMilliseconds)
            }
            let rest = milliseconds - pulseMilliseconds * beats
            if rest > 0 {
                frames.append(Frame(canvas: bright, milliseconds: rest))
            }
            return frames
        }

        /// A reset inside the rim: still and centred when it fits, one full pass
        /// from off the right edge when it does not — the same rule Compact's
        /// rows follow, over a wider area.
        ///
        /// The pulse is deliberately not here. A window showing its reset is
        /// being READ, and text that blinks under the eye is text nobody
        /// finishes.
        private static func resetFrames(
            vendor: Vendor, kind: WindowKind, percent: Int?,
            message: String, milliseconds: Int
        ) -> [Frame] {
            let area = resetLeft..<(PixelCanvas.width - 2)
            let width = font.width(of: message, scale: 1)
            guard width > area.count else {
                let x = area.lowerBound + (area.count - width) / 2
                return [Frame(
                    canvas: draw(vendor, kind: kind, percent: percent, value: (message, x)),
                    milliseconds: milliseconds
                )]
            }
            return stride(from: PixelCanvas.width, through: area.lowerBound - width, by: -1)
                .map { x in
                    Frame(
                        canvas: draw(vendor, kind: kind, percent: percent, value: (message, x)),
                        milliseconds: marqueeStepMilliseconds
                    )
                }
        }

        // MARK: - One picture

        /// One window: the rim at its reading, the mark in the corner, the name
        /// along the bottom, and either the figure or a reset inside.
        static func draw(
            _ vendor: Vendor, kind: WindowKind, percent: Int?,
            value: (text: String, x: Int)? = nil, dim: Bool = false, lit: Int? = nil
        ) -> PixelCanvas {
            var canvas = PixelCanvas()

            // A reading of nought lights no cell, so what colour it WOULD be
            // never shows — the whole rim is track either way.
            let ink = (percent ?? 0) > 0
                ? CodeUsage.fillColour(at: percent ?? 0, dim: dim)
                : CodeUsage.trackColour
            let filled = lit ?? litCells(percent)
            for (index, cell) in rim.enumerated() {
                canvas[cell.x, cell.y] = Pixel(colour: index < filled ? ink : CodeUsage.trackColour)
            }

            let logoInk = Pixel(colour: vendor.logoColour)
            for (dy, row) in vendor.logo.enumerated() {
                for (dx, mark) in row.enumerated() where mark == "#" {
                    canvas[markOrigin.x + dx, markOrigin.y + dy] = logoInk
                }
            }

            // The name and the figure are painted STRAIGHT onto the page, lit
            // pixels only. They overlap: the figure is nine rows from y3, the
            // name five from y9, so rows 9 to 11 belong to both. Drawn on a
            // strip and blitted — the way Compact's rows are, where nothing
            // overlaps — the second one's empty pixels erase the first one's
            // ink, and the name loses its top two rows wherever the figure's
            // box reaches over it.
            let nameInk = Pixel(colour: CodeUsage.labelColour)
            canvas.drawText(
                kind.name, at: PixelPoint(x: 2, y: nameY), ink: nameInk, font: font
            )

            let valueArea = resetLeft..<(PixelCanvas.width - 2)
            let valueInk = Pixel(colour: CodeUsage.figureColour(vendor, at: percent, dim: dim))
            guard let value else {
                let figure = CodeUsage.percentText(percent)
                canvas.drawText(
                    figure,
                    at: PixelPoint(x: figureRight - figureFont.width(of: figure, scale: 1),
                                   y: figureTop),
                    ink: valueInk, font: figureFont
                )
                return canvas
            }
            // The reset DOES need the strip: it enters from off the right edge
            // a pixel at a time, and the strip's own width is what stops it
            // reaching the mark. Nothing it blanks is drawn — the reset's five
            // rows from y4 sit above the name and clear of the mark's columns.
            var strip = PixelCanvas(width: valueArea.count, height: font.height)
            strip.drawText(
                value.text, at: PixelPoint(x: value.x - valueArea.lowerBound, y: 0),
                ink: valueInk, font: font
            )
            canvas.draw(strip, at: PixelPoint(x: valueArea.lowerBound, y: resetTop))
            return canvas
        }
    }
}
