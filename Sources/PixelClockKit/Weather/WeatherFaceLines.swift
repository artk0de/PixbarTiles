import Foundation

// The pieces the TC002 weather face is built from — the big temperature, the
// detail lines, the hourly chart and the Pages pages — each drawn on a strip
// of its own. `WeatherFaceTimelines.swift` arranges them in time. Every
// constant and every rounding is `wgen.py`'s (halves to even), because the
// oracle holds these pixels to it.

extension WeatherFace {
    // MARK: - Geometry and colours

    static let areaX = 18
    static let areaWidth = 34
    static let iconSide = 16
    static let height = 16

    static let label = rgb(0x60_60_60)
    static let dim = rgb(0x40_40_40)
    static let humidityInk = rgb(0x4D_A6_FF)
    static let rainInk = rgb(0x4D_A6_FF)
    static let rainCap = rgb(0xD8_F0_FF)
    static let sunInk = rgb(0xFF_B5_2E)

    static func rgb(_ value: UInt32) -> Pixel {
        Pixel(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    static func temperatureInk(_ celsius: Double) -> Pixel {
        Pixel(colour: UlanziColour(hex: TemperatureColour(celsius: celsius).hex))
    }

    /// Spec §3.4, in m/s whatever the display unit.
    static func windInk(metresPerSecond: Double) -> Pixel {
        for (limit, ink) in [(3.0, 0xCF_E8_F0), (8, 0x7C_FC_9A), (14, 0xFF_D2_4A), (20, 0xFF_8C_1A)]
        where metresPerSecond < limit {
            return rgb(UInt32(ink))
        }
        return rgb(0xFF_3B_30)
    }

    /// Spec §3.4, the WHO scale, of the whole index the line prints.
    static func uvInk(_ index: Int) -> Pixel {
        for (limit, ink) in [(3, 0x3E_C4_3E), (6, 0xFF_D2_4A), (8, 0xFF_8C_1A), (11, 0xFF_3B_30)]
        where index < limit {
            return rgb(UInt32(ink))
        }
        return rgb(0xB4_5A_FF)
    }

    static func halfEven(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    // MARK: - What a piece draws from

    /// A reading, the tile's settings and the facts read off them — the one
    /// input every piece draws from (wgen's `View`).
    struct Context {
        let reading: WeatherReading?
        let config: WeatherTileConfig
        let icon: WeatherIcon
        let hours: [WeatherReading.HourlyPoint]
        let rain: Int?
        let sun: (word: String, text: String)?

        init(reading: WeatherReading?, config: WeatherTileConfig, now: Date, timeZone: TimeZone) {
            self.reading = reading
            self.config = config
            icon = WeatherFacts.icon(for: reading, at: now)
            guard let reading else {
                hours = []
                rain = nil
                sun = nil
                return
            }
            hours = WeatherFacts.nextHours(at: now, in: reading, timeZone: timeZone)
            rain = WeatherFacts.rainChance(at: now, in: reading, timeZone: timeZone)
            switch WeatherFacts.nextSunEvent(after: now, in: reading) {
            case let .rise(at)?: sun = ("rise", Self.clockText(at, in: timeZone))
            case let .set(at)?: sun = ("set", Self.clockText(at, in: timeZone))
            case nil: sun = nil
            }
        }

        /// `H:MM`, no leading zero on the hour.
        private static func clockText(_ date: Date, in timeZone: TimeZone) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }

        /// The whole number the face prints for `celsius` in the tile's scale.
        func degrees(_ celsius: Double) -> Int {
            config.units == .fahrenheit ? halfEven(celsius * 9 / 5 + 32) : halfEven(celsius)
        }

        func degreesText(_ celsius: Double) -> String { "\(degrees(celsius))°" }

        var scaleText: String { config.units == .fahrenheit ? "f" : "c" }

        var windUnitText: String {
            switch config.windUnit {
            case .metresPerSecond: "m/s"
            case .kilometresPerHour: "km/h"
            case .milesPerHour: "mph"
            }
        }

        /// Gusts are shown when they beat the mean by 5 m/s, unrounded.
        var isGusty: Bool {
            guard let reading, let gusts = reading.windGusts else { return false }
            return WeatherFacts.metresPerSecond(kilometresPerHour: gusts)
                - WeatherFacts.metresPerSecond(kilometresPerHour: reading.windSpeed) >= 5
        }

        func windText(_ kilometresPerHour: Double) -> String {
            "\(WeatherFacts.speed(kilometresPerHour: kilometresPerHour, in: config.windUnit))"
        }
    }

    // MARK: - Runs of text

    /// One run of a line: its text, its ink, and the blank columns after it
    /// when they are not the default (3 after a grey label, 2 after a value).
    struct Part {
        let text: String
        let ink: Pixel
        var gap: Int?

        var gapAfter: Int { gap ?? (ink == WeatherFace.label ? 3 : 2) }
    }

    static func textWidth(_ text: String, font: PixelFontFace = .proportional) -> Int {
        font.width(of: text, scale: 1)
    }

    static func partsWidth(_ parts: [Part]) -> Int {
        parts.reduce(0) { $0 + textWidth($1.text) + $1.gapAfter } - (parts.last?.gapAfter ?? 0)
    }

    /// Draws `parts` left to right from `x`; answers the cursor after them.
    @discardableResult
    static func drawRuns(_ parts: [Part], on canvas: inout PixelCanvas, x: Int, y: Int) -> Int {
        var cursor = x
        for part in parts where part.text.isEmpty == false {
            canvas.drawText(part.text, at: PixelPoint(x: cursor, y: y), ink: part.ink, font: .proportional)
            cursor += textWidth(part.text) + part.gapAfter
        }
        return cursor
    }

    // MARK: - The temperature block

    /// Rows 0–8 of the right area: the air in the 5×9 digits, coloured from
    /// what it feels like (or the air), the scale's grey letter after it.
    static func temperatureBlock(_ context: Context, feelsColour: Bool) -> PixelCanvas {
        var block = PixelCanvas(width: areaWidth, height: 9)
        guard let reading = context.reading else {
            block.drawText("--°", at: .zero, ink: dim, font: PixelFont.big)
            return block
        }
        let colourFrom = feelsColour ? reading.apparentTemperature ?? reading.temperature : reading.temperature
        let text = context.degreesText(reading.temperature)
        block.drawText(text, at: .zero, ink: temperatureInk(colourFrom), font: PixelFont.big)
        let cursor = textWidth(text, font: PixelFont.big) + 1
        if cursor + 1 + textWidth(context.scaleText) <= areaWidth {
            block.drawText(context.scaleText, at: PixelPoint(x: cursor + 1, y: 4), ink: label, font: .proportional)
        }
        return block
    }

    // MARK: - Detail lines

    static func line(_ parts: [Part]) -> PixelCanvas {
        var strip = PixelCanvas(width: areaWidth, height: 5)
        drawRuns(parts, on: &strip, x: 0, y: 0)
        return strip
    }

    /// Today's high and low; the degree signs go first when both do not fit.
    static func hiloParts(_ context: Context, high: Double, low: Double) -> [Part] {
        var parts: [Part] = []
        for spell in [context.degreesText, { "\(context.degrees($0))" }] {
            parts = [
                Part(text: "↑", ink: label, gap: 1), Part(text: spell(high), ink: temperatureInk(high), gap: 3),
                Part(text: "↓", ink: label, gap: 1), Part(text: spell(low), ink: temperatureInk(low)),
            ]
            if partsWidth(parts) <= areaWidth { return parts }
        }
        return parts
    }

    static func windParts(_ context: Context, reading: WeatherReading, direction: Double) -> [Part] {
        let ink = windInk(metresPerSecond: WeatherFacts.metresPerSecond(kilometresPerHour: reading.windSpeed))
        let speed = context.windText(reading.windSpeed)
        var parts = [Part(text: String(WeatherFacts.arrow(fromDegrees: direction)), ink: ink, gap: 2)]
        if context.isGusty, let gusts = reading.windGusts {
            parts += [
                Part(text: speed, ink: ink), Part(text: "g", ink: label, gap: 1),
                Part(text: context.windText(gusts),
                     ink: windInk(metresPerSecond: WeatherFacts.metresPerSecond(kilometresPerHour: gusts))),
            ]
        } else {
            parts.append(Part(text: speed + " " + context.windUnitText, ink: ink))
        }
        return parts
    }

    /// The ticker's key: a detail the tile can switch, or `no data`.
    enum TickerKey: Hashable {
        case detail(WeatherTileConfig.Detail)
        case noData
    }

    /// Every line the ticker can show for this reading, keyed; a detail whose
    /// data is missing is absent. No reading is the one `no data` line.
    static func detailLines(_ context: Context) -> [TickerKey: PixelCanvas] {
        guard let reading = context.reading else {
            return [.noData: line([Part(text: "no data", ink: dim)])]
        }
        var lines: [TickerKey: PixelCanvas] = [:]
        if let felt = reading.apparentTemperature {
            lines[.detail(.feels)] = line([
                Part(text: "fl", ink: label), Part(text: context.degreesText(felt), ink: temperatureInk(felt)),
            ])
        }
        if let humidity = reading.relativeHumidity {
            lines[.detail(.humidity)] = line([
                Part(text: "h", ink: label), Part(text: "\(halfEven(humidity))%", ink: humidityInk),
            ])
        }
        if let direction = reading.windDirection {
            lines[.detail(.wind)] = line(windParts(context, reading: reading, direction: direction))
        }
        if let high = reading.todayHigh, let low = reading.todayLow {
            lines[.detail(.hilo)] = line(hiloParts(context, high: high, low: low))
        }
        if let chance = context.rain {
            lines[.detail(.rain)] = line([
                Part(text: "rain", ink: label), Part(text: "\(chance)%", ink: chance >= 30 ? rainInk : label),
            ])
        }
        if let uv = reading.uvIndex {
            let index = halfEven(uv)
            lines[.detail(.uv)] = line([Part(text: "uv", ink: label), Part(text: "\(index)", ink: uvInk(index))])
        }
        if let sun = context.sun {
            lines[.detail(.sun)] = line([Part(text: sun.word, ink: label), Part(text: sun.text, ink: sunInk)])
        }
        if context.hours.isEmpty == false {
            lines[.detail(.hourly)] = hourlyChart(context.hours)
        }
        return lines
    }

    /// Spec §3.3: a 2 px bar per hour, 1 px apart, 1–4 px tall within those
    /// hours' range (all equal: 2), coloured by temperature, with a pale cap
    /// where rain is likely.
    static func hourlyChart(_ hours: [WeatherReading.HourlyPoint]) -> PixelCanvas {
        var strip = PixelCanvas(width: areaWidth, height: 5)
        let temperatures = hours.map(\.temperature)
        guard let low = temperatures.min(), let high = temperatures.max() else { return strip }
        for (index, hour) in hours.enumerated() {
            let barHeight = high > low ? 1 + halfEven((hour.temperature - low) / (high - low) * 3) : 2
            let x = index * 3
            strip.drawRect(PixelRect(x: x, y: 5 - barHeight, width: 2, height: barHeight),
                           color: temperatureInk(hour.temperature))
            if let chance = hour.precipitationProbability, chance >= 50 {
                strip.drawRect(PixelRect(x: x, y: 4 - barHeight, width: 2, height: 1), color: rainCap)
            }
        }
        return strip
    }

    /// Hybrid: the icon a ticker line brings with it; nil keeps the weather's.
    static func itemIcon(_ context: Context, _ key: TickerKey) -> WeatherIcon? {
        guard let reading = context.reading, case let .detail(detail) = key else { return nil }
        switch detail {
        case .feels: return (reading.apparentTemperature ?? 0) >= 10 ? .feelsWarm : .feelsCold
        case .sun: return context.sun?.word == "rise" ? .sunrise : .sunset
        case .humidity: return .humidity
        case .wind: return .wind
        case .rain: return .umbrella
        case .uv: return .uv
        case .hilo, .hourly: return nil
        }
    }

    // MARK: - Pages (layout B)

    /// One page: its key (nil = the temperature page, which always shows),
    /// its icon and its 34×16 area.
    struct Page {
        let detail: WeatherTileConfig.Detail?
        let icon: WeatherIcon
        let area: PixelCanvas
    }

    private static func bigPage(_ value: String, ink: Pixel, labelParts: [Part]) -> PixelCanvas {
        var area = PixelCanvas(width: areaWidth, height: height)
        area.drawText(value, at: .zero, ink: ink, font: PixelFont.big)
        drawRuns(labelParts, on: &area, x: 0, y: 11)
        return area
    }

    /// Spec §3.5: the temperature page always, then feels, humidity and wind
    /// as the reading has them.
    static func pages(_ context: Context, feelsColour: Bool) -> [Page] {
        guard let reading = context.reading else {
            return [Page(detail: nil, icon: .nodata,
                         area: bigPage("--°", ink: dim, labelParts: [Part(text: "no data", ink: dim)]))]
        }
        var temperature = PixelCanvas(width: areaWidth, height: height)
        temperature.draw(temperatureBlock(context, feelsColour: feelsColour), at: .zero)
        if let high = reading.todayHigh, let low = reading.todayLow {
            drawRuns(hiloParts(context, high: high, low: low), on: &temperature, x: 0, y: 11)
        }
        var pages = [Page(detail: nil, icon: context.icon, area: temperature)]

        if let felt = reading.apparentTemperature {
            let text = context.degreesText(felt)
            var area = bigPage(text, ink: temperatureInk(felt), labelParts: [Part(text: "feels", ink: label)])
            let unitX = textWidth(text, font: PixelFont.big) + 1
            if unitX + textWidth(context.scaleText) <= areaWidth {
                area.drawText(context.scaleText, at: PixelPoint(x: unitX, y: 4), ink: label, font: .proportional)
            }
            pages.append(Page(detail: .feels, icon: felt >= 10 ? .feelsWarm : .feelsCold, area: area))
        }
        if let humidity = reading.relativeHumidity {
            pages.append(Page(detail: .humidity, icon: .humidity, area: bigPage(
                "\(halfEven(humidity))%", ink: humidityInk, labelParts: [Part(text: "humidity", ink: label)]
            )))
        }
        if let direction = reading.windDirection {
            var area = PixelCanvas(width: areaWidth, height: height)
            let ink = windInk(metresPerSecond: WeatherFacts.metresPerSecond(kilometresPerHour: reading.windSpeed))
            let speed = context.windText(reading.windSpeed)
            area.drawText(speed, at: .zero, ink: ink, font: PixelFont.big)
            let cursor = textWidth(speed, font: PixelFont.big) + 1
            area.drawText(context.windUnitText, at: PixelPoint(x: cursor + 2, y: 4), ink: label, font: .proportional)
            var parts = [Part(text: String(WeatherFacts.arrow(fromDegrees: direction)), ink: ink)]
            if context.isGusty, let gusts = reading.windGusts {
                parts += [
                    Part(text: "g", ink: label, gap: 1),
                    Part(text: context.windText(gusts),
                         ink: windInk(metresPerSecond: WeatherFacts.metresPerSecond(kilometresPerHour: gusts))),
                ]
            }
            drawRuns(parts, on: &area, x: 0, y: 11)
            pages.append(Page(detail: .wind, icon: .wind, area: area))
        }
        return pages
    }
}
