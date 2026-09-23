import Foundation

/// The unit the TC002 face prints the wind in.
///
/// The service keeps answering km/h; the face converts, so the setting is a
/// display choice and never changes what is asked for. Raw values are the
/// spellings the stored tile config and the face's oracle carry.
public enum WindUnit: String, Codable, Sendable, CaseIterable {
    case metresPerSecond
    case kilometresPerHour
    case milesPerHour

    /// Kilometres per hour in one of this unit.
    var kilometresPerHour: Double {
        switch self {
        case .metresPerSecond: 3.6
        case .kilometresPerHour: 1
        case .milesPerHour: 1.609344
        }
    }
}

/// What the TC002 face reads off a reading before it draws anything: which
/// icon, which moon, the next sun event, the chance of rain, the hours of the
/// chart, and the wind's arrow and units.
///
/// Held to the skill's `wgen.facts` by the oracle, so the arithmetic is
/// Python's: halves round to even (`round()`), and a modulo of a negative
/// number lands in `0..<divisor` (Python's floored `%`). Either one done the
/// Swift-default way moves an arrow or a moon phase on its boundary.
public enum WeatherFacts {
    // MARK: - Icon

    /// Spec §4.1, first match wins. Wind thresholds are in m/s, unrounded,
    /// whatever unit the tile prints. A clear night is the moon in its phase
    /// when the tile shows the moon (`showsMoon`), else the plain clear night.
    public static func icon(for reading: WeatherReading?, at now: Date, showsMoon: Bool = false) -> WeatherIcon {
        guard let reading else { return .nodata }
        let day = reading.isDay
        let air = reading.temperature
        let wind = metresPerSecond(kilometresPerHour: reading.windSpeed)
        let gusts = reading.windGusts.map { metresPerSecond(kilometresPerHour: $0) }
        let windy = wind >= 10 || (gusts ?? 0) >= 15
        func dayOrNight(_ dayIcon: WeatherIcon, _ nightIcon: WeatherIcon) -> WeatherIcon {
            day ? dayIcon : nightIcon
        }

        var code = reading.code
        switch code {
        case 96, 99:
            return .hail
        case 95:
            return wind >= 14 || (gusts ?? 0) >= 20 ? .storm : .thunder
        case 71, 73, 75, 77, 85, 86:
            if windy { return .blizzard }
            if code == 85 || code == 86 { return dayOrNight(.snowShowersDay, .snowShowersNight) }
            return .snow
        case 56, 57, 66, 67:
            return .freezingRain
        case 51, 53, 55, 61, 63, 65, 80, 81, 82:
            // The air decides before the code does: rain at 0…+2 °C is the
            // mixed fall the sleet art draws.
            if (0...2).contains(air) { return .sleet }
            switch code {
            case 51, 53, 55: return .drizzle
            case 61, 63: return .rain
            case 65, 82: return .heavyRain
            default: return dayOrNight(.showersDay, .showersNight)
            }
        case 45:
            return .fog
        case 48:
            return .rimeFog
        case 0, 1, 2, 3:
            break
        default:
            // The existing clear fallback: a code the table does not name is
            // drawn as the sky it most likely is, never as nothing.
            code = 0
        }

        if windy { return code == 3 ? .cloudWindy : dayOrNight(.windyDay, .windyNight) }
        if (code == 0 || code == 1) && day {
            if air >= 30 { return .hot }
            if air <= -10 { return .frostyClear }
        }
        switch code {
        case 0:
            if day { return .clearDay }
            return showsMoon ? moonIcon(moonPhase(at: now)) : .clearNight
        case 1:
            return dayOrNight(.mainlyClearDay, .mainlyClearNight)
        case 2:
            return dayOrNight(.partlyCloudyDay, .partlyCloudyNight)
        default:
            return dayOrNight(.cloudDay, .cloudNight)
        }
    }

    /// The moon drawn in `phase` (0–7, `moonPhase(at:)`).
    static func moonIcon(_ phase: Int) -> WeatherIcon {
        [.moon0, .moon1, .moon2, .moon3, .moon4, .moon5, .moon6, .moon7][phase]
    }

    // MARK: - Moon

    /// The new moon of 2000-01-06 18:14 UTC.
    static let newMoonEpoch: TimeInterval = 947_182_440
    static let synodicDays = 29.530588853

    /// Spec §4.2: 0 new, 2 first quarter, 4 full, 6 last quarter. A mean
    /// synodic month off one known new moon — a day or so off the true
    /// phase at worst, which is below what eight 16×16 drawings can show.
    public static func moonPhase(at date: Date) -> Int {
        let days = (date.timeIntervalSince1970 - newMoonEpoch) / 86_400
        let age = flooredModulo(days, synodicDays) / synodicDays
        return Int((age * 8).rounded(.toNearestOrEven)) % 8
    }

    // MARK: - Sun

    public enum SunEvent: Equatable, Sendable {
        case rise(Date)
        case set(Date)
    }

    /// Today's sunrise if it is still ahead, else today's sunset if it is,
    /// else tomorrow's sunrise; `nil` when the reading has none of those left.
    public static func nextSunEvent(after now: Date, in reading: WeatherReading) -> SunEvent? {
        let rises = reading.sunrises, sets = reading.sunsets
        if let rise = rises.first, now < rise { return .rise(rise) }
        if let set = sets.first, now < set { return .set(set) }
        if rises.count > 1, now < rises[1] { return .rise(rises[1]) }
        return nil
    }

    // MARK: - Rain and hours

    /// The highest precipitation probability over the current hour and the
    /// next two; `nil` when none of those hours has one — an unknown hour is
    /// skipped, never read as dry.
    ///
    /// The current hour is the hour on the clock of `timeZone`, the zone the
    /// face prints its times in, so a half-hour zone's window starts on its
    /// own half hour.
    public static func rainChance(
        at now: Date, in reading: WeatherReading, timeZone: TimeZone = .current
    ) -> Int? {
        let start = hourStart(of: now, in: timeZone)
        return reading.hourly
            .filter { $0.time >= start && $0.time < start.addingTimeInterval(3 * 3_600) }
            .compactMap(\.precipitationProbability)
            .max()
    }

    /// The hourly chart's entries: those in [current hour, +11 h), by time —
    /// at most eleven, fewer when the series is short.
    public static func nextHours(
        at now: Date, in reading: WeatherReading, timeZone: TimeZone = .current
    ) -> [WeatherReading.HourlyPoint] {
        let start = hourStart(of: now, in: timeZone)
        return reading.hourly
            .filter { $0.time >= start && $0.time < start.addingTimeInterval(11 * 3_600) }
            .sorted { $0.time < $1.time }
    }

    private static func hourStart(of date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    // MARK: - Wind

    /// Where the air GOES, rounded to eight directions. Open-Meteo reports
    /// where it comes from; an arrow pointing into the wind reads backwards
    /// on a clock face.
    public static func arrow(fromDegrees: Double) -> Character {
        let towards = flooredModulo(fromDegrees + 180, 360)
        let arrows: [Character] = ["⇑", "⇗", "⇒", "⇘", "⇓", "⇙", "⇐", "⇖"]
        return arrows[Int((towards / 45).rounded(.toNearestOrEven)) % 8]
    }

    /// Every wind threshold and colour is in m/s, unrounded.
    public static func metresPerSecond(kilometresPerHour: Double) -> Double {
        kilometresPerHour / 3.6
    }

    /// The whole number the face prints for a service speed in `unit`.
    public static func speed(kilometresPerHour: Double, in unit: WindUnit) -> Int {
        Int((kilometresPerHour / unit.kilometresPerHour).rounded(.toNearestOrEven))
    }

    /// Python's `%`: the result takes the divisor's sign.
    private static func flooredModulo(_ value: Double, _ divisor: Double) -> Double {
        let remainder = fmod(value, divisor)
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder
    }
}
