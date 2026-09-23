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

    /// The SPENT part of a bar — the progress itself — while the window is
    /// steady.
    ///
    /// Bright white, so what a glance lands on is how much of it is gone
    /// against the grey of what is left. White stands where a vendor's brand
    /// colour used to: the figure beside the bar already says which account
    /// this is, so the bar is free to spend its colour on how much is left.
    static let steadyProgressColour = "#FFFFFF"

    /// What the spent part is drawn in at `percent`, and `dim` on the low half
    /// of the spent pulse.
    ///
    /// White while the window is steady, and `UsageBand`'s ramp past three
    /// quarters — the same yellow through red the AWTRIX page uses, so a colour
    /// means the same thing wherever it shows. White alone left a bar at a
    /// third and a bar about to run out the same colour, differing only in
    /// length, which is the one reading a 52-pixel row is worst at.
    static func fillColour(at percent: Int, dim: Bool = false) -> UlanziColour {
        let band = UsageBand(utilization: percent)
        if dim, let pulse = band.pulseColour { return UlanziColour(hex: pulse) }
        return UlanziColour(hex: band.fillColour(brand: steadyProgressColour))
    }

    /// A figure's ink: the vendor's MARK while the window is steady, the bar's
    /// own colour once it is not, and the track's grey for a row nobody knows.
    ///
    /// While nothing is near a limit the figure is identity — WHICH account
    /// this is — and the bar alone carries how much is left. Past three
    /// quarters that split stops paying: the figure and the bar under it are
    /// one statement, and a warm figure over a warm bar is what the eye lands
    /// on first. (z.ai's mark is near-white where its brand is blue, which is
    /// why this reads the mark and never the brand.)
    static func figureColour(_ vendor: Vendor, at percent: Int?, dim: Bool = false)
        -> UlanziColour
    {
        guard let percent else { return trackColour }
        guard UsageBand(utilization: percent) != .steady else { return vendor.logoColour }
        return fillColour(at: percent, dim: dim)
    }
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
        config: UsageFaceConfig, timeZone: TimeZone
    ) -> [Frame] {
        let windows = [session, weekly]
        let hot = windows.map { window in
            guard let window, window.resetsAt != nil else { return false }
            return window.percent >= config.resetAfter
        }
        let percents = windows.map { $0.map { percentText($0.percent) } ?? "--" }
        let phase = percentPhase(
            vendor, windows,
            values: percents.map { (text: $0, x: nil) },
            milliseconds: Int((config.resetEvery * 1000).rounded())
        )
        guard hot.contains(true) else { return phase }

        let messages = [
            session?.resetsAt.map { sessionReset($0, in: timeZone) },
            weekly?.resetsAt.map { weeklyReset($0, in: timeZone) },
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
        let spent = windows.contains { $0.map { UsageBand(utilization: $0.percent) == .spent } ?? false }
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
                ink: Pixel(colour: labelColour), font: font
            )
            // The value on a strip as wide as its area, laid on the page: the
            // strip's edge is the clip, so a scrolling reset never reaches
            // the label.
            let area = valueArea(index)
            var strip = PixelCanvas(width: area.count, height: font.height)
            let x = value.x ?? PixelCanvas.width - font.width(of: value.text, scale: 1)
            strip.drawText(
                value.text, at: PixelPoint(x: x - area.lowerBound, y: 0),
                ink: Pixel(colour: figureColour(vendor, at: window?.percent, dim: dim)), font: font
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
                    color: Pixel(colour: fillColour(at: window.percent, dim: dim))
                )
            }
        }
        return canvas
    }
}
