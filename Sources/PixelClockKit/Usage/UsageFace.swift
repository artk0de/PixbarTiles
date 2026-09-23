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
/// - A hot `s` row flips to `rst HH:mm` — it fits its value area, so it is
///   still. With only `s` hot, that is one frame of five seconds.
/// - A hot `w` row's `rst d mmm HH:mm` does not fit, so it glides through its
///   value area one pixel a frame: readable at the area's left edge for a
///   second, then 100 ms a step until its tail meets the panel's edge, held a
///   second and a half. A hot `s` shows its reset in every one of those
///   frames.
///
/// Reset times are INSTANTS, said in the zone the face is drawn in — the
/// Mac's — whatever zone the vendor's server keeps (z.ai's is Asia/Shanghai).
public enum UsageFace {
    /// A vendor's look: its mark, the colour the mark is drawn in, and the
    /// brand colour a steady figure and bar are drawn in.
    public struct Vendor: Sendable, Equatable {
        /// The mark as rows of `#` (lit) and `.`, at most 8 × 5.
        public let logo: [String]
        public let logoColour: UlanziColour
        /// `#RRGGBB`, what `UsageBand.fillColour(brand:)` answers below the
        /// first warning.
        public let brand: String

        /// The Claude crab, in Claude's orange.
        public static let claude = Vendor(
            logo: [
                ".######.",
                ".#.##.#.",
                "########",
                ".######.",
                ".##..##.",
            ],
            logoColour: UlanziColour(hex: ClaudeUsage.brandColour),
            brand: ClaudeUsage.brandColour
        )

        /// z.ai's "Z", in near-white: the plan's blue is the figures' colour,
        /// and a blue mark beside blue figures would read as one more figure.
        public static let zai = Vendor(
            logo: [
                "#######",
                "....##.",
                "..###..",
                ".##....",
                "#######",
            ],
            logoColour: UlanziColour(value: 0xE8_E8_E8),
            brand: ZaiUsage.brandColour
        )
    }

    /// One row's reading: how much of the window is gone — past a hundred is
    /// allowed, and drawn as a hundred — and when it starts again, when the
    /// source said. A row with no reading at all is a nil `Window`.
    public struct Window: Sendable, Equatable {
        public let percent: Int
        public let resetsAt: Date?

        public init(percent: Int, resetsAt: Date?) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// One picture of the timeline and how long the panel shows it.
    public struct Frame: Sendable, Equatable {
        public let canvas: PixelCanvas
        public let milliseconds: Int
    }

    // MARK: - Layout (gen.py's constants)

    static let labelColour = UlanziColour(value: 0x60_60_60)
    /// The bar's unlit track, and the ink of a figure nobody knows — the same
    /// grey as `ClaudeUsageConnector.trackColour`, and for the same reason.
    static let trackColour = UlanziColour(value: 0x30_30_30)

    /// The SPENT part of a bar — the progress itself.
    ///
    /// Bright white, so what a glance lands on is how much of the window is
    /// gone, against the grey of what is left. The warning bands no longer
    /// colour it: a page that turned red at 95% put the loudest thing on the
    /// panel on the tile with the least to say. `UsageBand` still classifies
    /// and the AWTRIX page still draws its bar in the band's colour; only
    /// this face stopped.
    static let progressColour = UlanziColour(value: 0xFF_FF_FF)
    private static let logoOrigin = PixelPoint(x: 0, y: 1)
    private static let labelX = 9
    /// The box the two labels are centred in — the wider of them.
    ///
    /// In the proportional face "s" is three columns wide and "w" is five, so
    /// flush left they hang off one another by two pixels: one row's mark
    /// visibly left of the other's, on a panel where the two rows are read as
    /// a pair.
    private static var labelBox: Int {
        rows.map { font.width(of: $0.label, scale: 1) }.max() ?? 0
    }

    private static func labelX(of label: String) -> Int {
        labelX + (labelBox - font.width(of: label, scale: 1)) / 2
    }
    /// Columns between a label and the value area. Fewer, and a scrolling
    /// value reads as one word with its label.
    private static let labelGap = 4
    private static let rows: [(label: String, top: Int)] = [("s", 1), ("w", 9)]

    /// How long the session's reset stands when it is the only thing to say.
    private static let dwellMilliseconds = 5_000
    private static let marqueeHoldStart = 1_000
    private static let marqueeStep = 100
    private static let marqueeHoldEnd = 1_500

    private static let font = PixelFont.proportional

    // MARK: - The timeline

    /// The page as the panel plays it: frame A, then the reset phase for the
    /// rows `config` calls hot. A row is hot when it has a reading at or past
    /// `resetAfter` AND a reset date — a hot row whose source named no reset
    /// has nothing to flip to, and the page stays the percentages rather than
    /// inventing a time.
    public static func timeline(
        vendor: Vendor, session: Window?, weekly: Window?,
        config: UsageFaceConfig, timeZone: TimeZone
    ) -> [Frame] {
        let windows = [session, weekly]
        let hot = windows.map { window in
            guard let window, window.resetsAt != nil else { return false }
            return window.percent >= config.resetAfter
        }
        let percents = windows.map { $0.map { percentText($0.percent) } ?? "--" }
        let first = Frame(
            canvas: draw(vendor, windows, values: percents.map { (text: $0, x: nil) }),
            milliseconds: Int((config.resetEvery * 1000).rounded())
        )
        guard hot.contains(true) else { return [first] }

        let sessionValue: (text: String, x: Int?) = if hot[0], let at = session?.resetsAt {
            (sessionReset(at, in: timeZone), nil)
        } else {
            (percents[0], nil)
        }
        guard hot[1], let weeklyAt = weekly?.resetsAt else {
            let flipped = draw(vendor, windows, values: [sessionValue, (percents[1], nil)])
            return [first, Frame(canvas: flipped, milliseconds: dwellMilliseconds)]
        }

        // The edge marquee: start readable at the area's left edge, glide one
        // pixel a frame until the tail shows, hold both ends.
        let message = weeklyReset(weeklyAt, in: timeZone)
        let area = valueArea(label: rows[1].label)
        let end = min(area.lowerBound, area.upperBound - font.width(of: message, scale: 1))
        let positions = Array(stride(from: area.lowerBound, through: end, by: -1))
        var frames = [first]
        for (index, x) in positions.enumerated() {
            let milliseconds =
                index == 0 ? marqueeHoldStart
                : index == positions.count - 1 ? marqueeHoldEnd
                : marqueeStep
            frames.append(Frame(
                canvas: draw(vendor, windows, values: [sessionValue, (message, x)]),
                milliseconds: milliseconds
            ))
        }
        return frames
    }

    /// The timeline as the one page the TC002 plays by itself: a full-frame
    /// GIF, each frame's own delay, at the panel's origin (the `image[]`
    /// envelope measured in §6f).
    ///
    /// Should the GIF ever fail to encode — it cannot for these frames: a
    /// handful of colours, one panel size — the page falls back to frame A as
    /// the plain bitmap, which says the percentages rather than nothing.
    public static func delivery(
        vendor: Vendor, session: Window?, weekly: Window?,
        config: UsageFaceConfig, timeZone: TimeZone
    ) -> UlanziDelivery {
        let frames = timeline(
            vendor: vendor, session: session, weekly: weekly, config: config, timeZone: timeZone
        )
        guard
            let gif = try? FullFrameGif.encode(
                frames: frames.map(\.canvas),
                delays: frames.map { TimeInterval($0.milliseconds) / 1000 }
            )
        else {
            return UlanziDelivery(scene: UlanziScene(frames: [
                UlanziFrame(duration: 5, draw: [frames[0].canvas.drawCommands()]),
            ]))
        }
        let image = UlanziImage(
            base64: gif.base64EncodedString(),
            isAnimated: frames.count > 1,
            frameCount: frames.count,
            pixelSize: (width: PixelCanvas.width, height: PixelCanvas.height),
            position: (x: 0, y: 0)
        )
        return UlanziDelivery(scene: UlanziScene(frames: [UlanziFrame(duration: 5, image: [image])]))
    }

    // MARK: - Reset spellings

    /// `rst 14:30` — the session's reset, in `timeZone`, 24-hour.
    public static func sessionReset(_ date: Date, in timeZone: TimeZone) -> String {
        let parts = components(of: date, in: timeZone)
        return "rst " + clock(parts)
    }

    /// `rst 1 oct 09:00` — the week's reset, in `timeZone`: the day without a
    /// leading zero, the month's three lowercase letters, no comma.
    public static func weeklyReset(_ date: Date, in timeZone: TimeZone) -> String {
        let parts = components(of: date, in: timeZone)
        let month = months[(parts.month ?? 1) - 1]
        return "rst \(parts.day ?? 1) \(month) " + clock(parts)
    }

    /// English abbreviations spelled out rather than asked of a formatter: a
    /// locale's own abbreviation can carry a dot or a letter the face has no
    /// glyph for, and this one must be exactly what the panel can draw.
    private static let months = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    private static func components(of date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    }

    private static func clock(_ parts: DateComponents) -> String {
        String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: - One picture

    private static func percentText(_ percent: Int) -> String {
        "\(min(percent, 100))%"
    }

    /// The columns a row's value may use: from the label, plus the gap, to
    /// the panel's edge.
    private static func valueArea(label: String) -> Range<Int> {
        (labelX + font.width(of: label, scale: 1) + labelGap)..<PixelCanvas.width
    }

    /// One frame: the mark, and per row its label, its value — right-aligned
    /// when `x` is nil, clipped to the row's value area either way — and its
    /// bar.
    private static func draw(
        _ vendor: Vendor, _ windows: [Window?], values: [(text: String, x: Int?)]
    ) -> PixelCanvas {
        var canvas = PixelCanvas()
        let logoInk = Pixel(colour: vendor.logoColour)
        for (dy, row) in vendor.logo.enumerated() {
            for (dx, mark) in row.enumerated() where mark == "#" {
                canvas[logoOrigin.x + dx, logoOrigin.y + dy] = logoInk
            }
        }
        for ((label, top), (window, value)) in zip(rows, zip(windows, values)) {
            canvas.drawText(
                label, at: PixelPoint(x: labelX(of: label), y: top),
                ink: Pixel(colour: labelColour), font: font
            )
            // The value on a strip as wide as its area, laid on the page: the
            // strip's edge is the clip, so a scrolling reset never reaches
            // the label.
            let area = valueArea(label: label)
            var strip = PixelCanvas(width: area.count, height: font.height)
            let x = value.x ?? PixelCanvas.width - font.width(of: value.text, scale: 1)
            // The figure in the vendor's MARK colour, not the band's. The mark
            // and the figures are the tile's identity — which account this is
            // — while the band is about how much is left, which the bar under
            // it already says in colour and in length. z.ai's mark is
            // near-white where its brand is blue, so blue figures under a
            // white Z read as a second vendor on one page.
            strip.drawText(
                value.text, at: PixelPoint(x: x - area.lowerBound, y: 0),
                ink: Pixel(colour: window == nil ? trackColour : vendor.logoColour), font: font
            )
            canvas.draw(strip, at: PixelPoint(x: area.lowerBound, y: top))

            let barY = top + 6
            canvas.drawRect(
                PixelRect(x: 0, y: barY, width: PixelCanvas.width, height: 1),
                color: Pixel(colour: trackColour)
            )
            if let window, window.percent > 0 {
                let filled = max(1, (PixelCanvas.width * min(window.percent, 100) + 50) / 100)
                canvas.drawRect(
                    PixelRect(x: 0, y: barY, width: filled, height: 1),
                    color: Pixel(colour: progressColour)
                )
            }
        }
        return canvas
    }
}
