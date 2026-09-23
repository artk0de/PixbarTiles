import Foundation

/// The TC002 weather face (spec `2026-09-23-tc002-weather-face-design.md`):
/// a 16×16 animated icon, the temperature in the 5×9 digits, and a rotating
/// detail line, in one of three layouts.
///
/// The design was approved as the frames the `tc002-face-mockup` skill's
/// `weather/wgen.py` computes; `WeatherFaceOracleTests` holds this type to
/// them pixel for pixel and delay for delay. Every constant is wgen's, and a
/// change of design starts THERE.
///
/// - **Anchor**: the icon loops on its own; the right area's temperature
///   stands still while the detail line slides. Two independent timelines —
///   nothing has to line up, so two GIFs may drift.
/// - **Pages** and **Hybrid**: one 52×16 timeline, because there the icon
///   changes WITH the text and only one GIF keeps the two in step.
///
/// The pieces are drawn in `WeatherFaceLines.swift`, arranged in time in
/// `WeatherFaceTimelines.swift`.
public enum WeatherFace {
    /// One picture of a timeline and how long it shows.
    public struct Frame: Sendable, Equatable {
        public let canvas: PixelCanvas
        public let milliseconds: Int
    }

    /// Anchor: the icon (16×16) and the right area (34×16) loop independently.
    public struct Layered: Sendable, Equatable {
        public let icon: [Frame]
        public let area: [Frame]
    }

    public enum Timeline: Sendable, Equatable {
        case layered(Layered)
        /// Pages and Hybrid: one 52×16 sequence.
        case single([Frame])
    }

    /// The ceilings of one animated image on the TC002, measured live on
    /// 2026-09-23 (478 frames / 135 240 bytes of base64 played on time) —
    /// `UlanziScene` enforces the same.
    static let maxFrames = 480, maxBase64Bytes = 136_000
    /// Over budget, each state's icon plays whole loops for at least this
    /// long after its change, then rests on its first frame.
    static let burstMilliseconds = 2_000

    public static func timeline(
        reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone
    ) -> Timeline {
        let context = Context(reading: reading, config: config, now: now, timeZone: timeZone)
        guard config.layout == .anchor else {
            return .single(composed(context).frames)
        }
        let icon = context.icon.frames.map { Frame(canvas: $0.canvas, milliseconds: $0.milliseconds) }
        let area = areaTimeline(context, hybrid: false).map {
            Frame(canvas: $0.canvas, milliseconds: $0.milliseconds)
        }
        return .layered(Layered(icon: icon, area: area))
    }

    /// The whole panel as one sequence, for the preview. Pages and Hybrid
    /// already are one; Anchor's two clocks are merged over one cycle of the
    /// area — a new frame whenever either ticks (weather_demo's `merged`).
    public static func preview(
        reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone
    ) -> [Frame] {
        switch timeline(reading: reading, config: config, now: now, timeZone: timeZone) {
        case let .single(frames):
            return frames
        case let .layered(layered):
            return merged(icon: layered.icon, area: layered.area)
        }
    }

    // MARK: - The budget

    /// Pages / Hybrid with the burst the budget settled on (nil: the icons
    /// loop through every dwell).
    static func composed(
        reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone
    ) -> (frames: [Frame], burstMilliseconds: Int?) {
        composed(Context(reading: reading, config: config, now: now, timeZone: timeZone))
    }

    private static func composed(_ context: Context) -> (frames: [Frame], burstMilliseconds: Int?) {
        let build = context.config.layout == .pages ? pagesSequence : hybridSequence
        let looping = build(context, nil)
        if fits(looping) { return (looping, nil) }
        return (build(context, burstMilliseconds), burstMilliseconds)
    }

    /// Whether one GIF of `frames` stays within the measured ceilings — the
    /// real encoder's bytes, not an estimate. A GIF that cannot be encoded
    /// does not fit.
    static func fits(_ frames: [Frame]) -> Bool {
        guard frames.count <= maxFrames, let gif = try? gif(frames) else { return false }
        return (gif.count + 2) / 3 * 4 <= maxBase64Bytes
    }

    static func gif(_ frames: [Frame]) throws -> Data {
        try FullFrameGif.encode(
            frames: frames.map(\.canvas),
            delays: frames.map { TimeInterval($0.milliseconds) / 1000 }
        )
    }

    // MARK: - The preview merge

    private static func merged(icon: [Frame], area: [Frame]) -> [Frame] {
        func cuts(_ frames: [Frame]) -> (starts: [Int], total: Int) {
            var starts: [Int] = [], elapsed = 0
            for frame in frames {
                starts.append(elapsed)
                elapsed += frame.milliseconds
            }
            return (starts, elapsed)
        }
        let (iconCuts, iconLength) = cuts(icon)
        let (areaCuts, total) = cuts(area)
        guard iconLength > 0, total > 0 else { return [] }
        var times = Set(areaCuts)
        for loop in 0...(total / iconLength) {
            for cut in iconCuts where cut + loop * iconLength < total {
                times.insert(cut + loop * iconLength)
            }
        }
        let ordered = times.sorted()
        return ordered.enumerated().map { index, time in
            let end = index + 1 < ordered.count ? ordered[index + 1] : total
            let iconIndex = iconCuts.lastIndex { $0 <= time % iconLength } ?? 0
            let areaIndex = areaCuts.lastIndex { $0 <= time } ?? 0
            return Frame(canvas: compose(icon[iconIndex].canvas, area[areaIndex].canvas), milliseconds: end - time)
        }
    }
}
