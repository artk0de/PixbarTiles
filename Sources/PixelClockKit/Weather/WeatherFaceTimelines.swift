import Foundation

// The TC002 weather face in time (spec §2, §2.2): Anchor's right area, the
// Pages sequence and the Hybrid sequence, and how an icon plays through a
// dwell. Ports of `wgen.area_timeline`, `play`, `pages_full` and
// `hybrid_full`; the pieces come from `WeatherFaceLines.swift`.

extension WeatherFace {
    // MARK: - Timing (wgen's constants)

    /// Ticker: 1 row per step, 5 rows + 1 blank.
    static let stepMilliseconds = 60, slideSteps = 6
    /// Hybrid: the icon slides 3 rows per ticker step.
    static let iconStep = 3
    /// Pages: the whole panel slides 2 rows per step.
    static let pageStepMilliseconds = 40, pageSteps = 8
    /// Anchor's area with a single state.
    static let stillMilliseconds = 1_000

    typealias Cel = (canvas: PixelCanvas, milliseconds: Int)

    /// One state of the right area: its frame, how long it shows, and the
    /// icon it goes with (the weather's, or in Hybrid the line's own).
    struct TaggedArea {
        let canvas: PixelCanvas
        let milliseconds: Int
        let icon: WeatherIcon
    }

    static func changeMilliseconds(_ config: WeatherTileConfig) -> Int {
        Int((config.changeEvery * 1000).rounded())
    }

    // MARK: - Rows

    /// A copy of `canvas` with row `y` replaced by `source`'s row `sourceY`
    /// (nil: unlit), across `source`'s width from column `x`.
    private static func copyRow(
        _ source: PixelCanvas?, _ sourceY: Int, into canvas: inout PixelCanvas, row y: Int, width: Int
    ) {
        for x in 0..<width {
            canvas[x, y] = source?[x, sourceY] ?? .black
        }
    }

    // MARK: - Anchor / Hybrid right area

    /// The right 34×16: temperature fixed on rows 0–8, the ticker on rows
    /// 11–15. Each state: its dwell frame, then `slideSteps - 1` slide steps.
    static func areaTimeline(_ context: Context, hybrid: Bool) -> [TaggedArea] {
        let top = temperatureBlock(context, feelsColour: context.config.feelsLikeColour)
        let lines = detailLines(context)
        let keys: [TickerKey] = lines[.noData] != nil
            ? [.noData]
            : context.config.details.map(TickerKey.detail).filter { lines[$0] != nil }
        let ticker = keys.map { lines[$0]! }

        func icon(of key: TickerKey) -> WeatherIcon {
            (hybrid ? itemIcon(context, key) : nil) ?? context.icon
        }
        func frame(_ current: PixelCanvas?, _ next: PixelCanvas?, _ step: Int) -> PixelCanvas {
            var canvas = PixelCanvas(width: areaWidth, height: height)
            canvas.draw(top, at: .zero)
            for row in 0..<5 {
                let source = row + step
                if source < 5 {
                    copyRow(current, source, into: &canvas, row: 11 + row, width: areaWidth)
                } else if (6..<11).contains(source) {
                    copyRow(next, source - 6, into: &canvas, row: 11 + row, width: areaWidth)
                }
            }
            return canvas
        }

        guard ticker.count >= 2 else {
            let only = ticker.first
            return [TaggedArea(canvas: frame(only, only, 0), milliseconds: stillMilliseconds,
                               icon: keys.first.map(icon(of:)) ?? context.icon)]
        }
        let dwell = changeMilliseconds(context.config)
        var out: [TaggedArea] = []
        for (index, current) in ticker.enumerated() {
            let next = ticker[(index + 1) % ticker.count]
            let brought = icon(of: keys[index])
            out.append(TaggedArea(canvas: frame(current, next, 0), milliseconds: dwell, icon: brought))
            for step in 1..<slideSteps {
                out.append(TaggedArea(canvas: frame(current, next, step), milliseconds: stepMilliseconds,
                                      icon: brought))
            }
        }
        return out
    }

    // MARK: - An icon through a dwell

    /// An icon over `total` ms: whole loops until at least `burst` ms have
    /// played, then its first frame holds for the rest (nil: loop all). A
    /// sliver under 20 ms joins the frame before it.
    static func play(_ loop: [Cel], total: Int, burst: Int?) -> [Cel] {
        var out: [Cel] = []
        var elapsed = 0, index = 0
        while elapsed < total {
            if let burst, elapsed >= burst, index % loop.count == 0 {
                out.append((loop[0].canvas, total - elapsed))
                break
            }
            let cel = loop[index % loop.count]
            let milliseconds = min(cel.milliseconds, total - elapsed)
            if milliseconds < 20, out.isEmpty == false {
                out[out.count - 1].milliseconds += milliseconds
            } else {
                out.append((cel.canvas, milliseconds))
            }
            elapsed += milliseconds
            index += 1
        }
        return out
    }

    static func loopMilliseconds(_ loop: [Cel]) -> Int {
        loop.reduce(0) { $0 + $1.milliseconds }
    }

    /// The icon beside the area on the 52×16 panel, the gutter unlit.
    static func compose(_ icon: PixelCanvas, _ area: PixelCanvas) -> PixelCanvas {
        var canvas = PixelCanvas()
        canvas.draw(icon, at: .zero)
        canvas.draw(area, at: PixelPoint(x: areaX, y: 0))
        return canvas
    }

    // MARK: - Pages

    /// Layout B as one 52×16 timeline: during a dwell the icon animates
    /// beside a still page; on a change the whole page slides up 2 rows a
    /// step, 2 blank rows between. A single page is a still dwell of one
    /// whole icon loop.
    static func pagesSequence(_ context: Context, burst: Int?) -> [Frame] {
        let shown = pages(context, feelsColour: context.config.feelsLikeColour).filter { page in
            page.detail.map(context.config.details.contains) ?? true
        }
        if shown.count == 1 {
            let loop = shown[0].icon.frames
            return play(loop, total: loopMilliseconds(loop), burst: burst).map {
                Frame(canvas: compose($0.canvas, shown[0].area), milliseconds: $0.milliseconds)
            }
        }
        let dwell = changeMilliseconds(context.config)
        var out: [Frame] = []
        for (index, page) in shown.enumerated() {
            let sequence = play(page.icon.frames, total: dwell, burst: burst)
            out += sequence.map { Frame(canvas: compose($0.canvas, page.area), milliseconds: $0.milliseconds) }
            let next = shown[(index + 1) % shown.count]
            let current = compose(sequence[sequence.count - 1].canvas, page.area)
            let incoming = compose(next.icon.frames[0].canvas, next.area)
            for step in 1...pageSteps {
                var canvas = PixelCanvas()
                for row in 0..<height {
                    let source = row + 2 * step
                    if source < height {
                        copyRow(current, source, into: &canvas, row: row, width: PixelCanvas.width)
                    } else if (18..<34).contains(source) {
                        copyRow(incoming, source - 18, into: &canvas, row: row, width: PixelCanvas.width)
                    }
                }
                out.append(Frame(canvas: canvas, milliseconds: pageStepMilliseconds))
            }
        }
        return out
    }

    // MARK: - Hybrid

    /// Hybrid as one 52×16 timeline: the temperature never moves; on a change
    /// the line slides 1 row a step and its icon 3 rows a step over the SAME
    /// steps — both land together. A single state is a still dwell of one
    /// whole icon loop.
    static func hybridSequence(_ context: Context, burst: Int?) -> [Frame] {
        let tagged = areaTimeline(context, hybrid: true)
        if tagged.count == 1 {
            let loop = tagged[0].icon.frames
            return play(loop, total: loopMilliseconds(loop), burst: burst).map {
                Frame(canvas: compose($0.canvas, tagged[0].canvas), milliseconds: $0.milliseconds)
            }
        }
        var out: [Frame] = []
        let states = tagged.count / slideSteps
        for state in 0..<states {
            let dwell = tagged[state * slideSteps]
            let sequence = play(dwell.icon.frames, total: dwell.milliseconds, burst: burst)
            out += sequence.map { Frame(canvas: compose($0.canvas, dwell.canvas), milliseconds: $0.milliseconds) }
            let last = sequence[sequence.count - 1].canvas
            let incoming = tagged[((state + 1) % states) * slideSteps].icon.frames[0].canvas
            for step in 1..<slideSteps {
                let slide = tagged[state * slideSteps + step]
                var icon = PixelCanvas(width: iconSide, height: iconSide)
                for row in 0..<iconSide {
                    let source = row + iconStep * step
                    if source < iconSide {
                        copyRow(last, source, into: &icon, row: row, width: iconSide)
                    } else if (18..<34).contains(source) {
                        copyRow(incoming, source - 18, into: &icon, row: row, width: iconSide)
                    }
                }
                out.append(Frame(canvas: compose(icon, slide.canvas), milliseconds: slide.milliseconds))
            }
        }
        return out
    }
}
