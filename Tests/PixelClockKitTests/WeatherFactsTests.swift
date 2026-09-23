import Foundation
import Testing
@testable import PixelClockKit

// What the face reads off a reading before it draws anything: the icon (spec
// §4.1, first match wins), the moon (§4.2), the next sun event, the rain
// window and the hours of the chart (§3.2, §3.3), the wind's arrow and units.
// The oracle cross-check holds all of it to the skill's `wgen.facts`; the
// rule tests below name each rule with the numbers that sit on its edge.

private let utc = TimeZone(identifier: "UTC")!

private func reading(
    code: Int = 0, isDay: Bool = true, temperature: Double = 15,
    wind: Double = 0, gusts: Double? = nil, direction: Double? = nil,
    sunrises: [Date] = [], sunsets: [Date] = [], hourly: [WeatherReading.HourlyPoint] = []
) -> WeatherReading {
    WeatherReading(
        code: code, isDay: isDay, temperature: temperature, precipitation: 0,
        windSpeed: wind, interval: 900, windDirection: direction, windGusts: gusts,
        sunrises: sunrises, sunsets: sunsets, hourly: hourly
    )
}

private let noon = Date(timeIntervalSince1970: 1_790_164_800)   // 2026-09-23 12:00 UTC

private func icon(_ reading: WeatherReading) -> WeatherIcon {
    WeatherFacts.icon(for: reading, at: noon)
}

// MARK: - The oracle

@Test func everyOracleCaseAgreesOnTheFacts() throws {
    let oracle = try WeatherOracle.load()
    for c in oracle.cases {
        let r = c.reading.map(\.appReading)
        let facts = c.facts
        #expect(WeatherFacts.icon(for: r, at: c.now).rawValue == facts.icon, "\(c.id) icon")
        #expect(WeatherFacts.moonPhase(at: c.now) == facts.moon, "\(c.id) moon")
        guard let r else {
            #expect(facts.sun == nil && facts.rain == nil && facts.arrow == nil && facts.hours.isEmpty, "\(c.id)")
            continue
        }
        #expect(WeatherFacts.rainChance(at: c.now, in: r, timeZone: oracle.timeZone) == facts.rain, "\(c.id) rain")
        #expect(
            WeatherFacts.nextHours(at: c.now, in: r, timeZone: oracle.timeZone).map(\.time.timeIntervalSince1970)
                == facts.hours, "\(c.id) hours"
        )
        let sun = WeatherFacts.nextSunEvent(after: c.now, in: r)
        switch (sun, facts.sun) {
        case (nil, nil): break
        case let (.rise(at)?, expected?):
            #expect(expected.event == "rise" && at.timeIntervalSince1970 == expected.at, "\(c.id) sun")
        case let (.set(at)?, expected?):
            #expect(expected.event == "set" && at.timeIntervalSince1970 == expected.at, "\(c.id) sun")
        default:
            Issue.record("\(c.id) sun: \(String(describing: sun)) vs \(String(describing: facts.sun))")
        }
        #expect(r.windDirection.map { String(WeatherFacts.arrow(fromDegrees: $0)) } == facts.arrow, "\(c.id) arrow")
    }
}

// MARK: - §4.1 icon selection, first match wins

@Test func noReadingIsTheNoDataCloud() {
    #expect(WeatherFacts.icon(for: nil, at: noon) == .nodata)
}

@Test func codes96And99AreHailWhateverTheWind() {
    #expect(icon(reading(code: 96)) == .hail)
    #expect(icon(reading(code: 99, wind: 80)) == .hail)
}

@Test func stormNeedsFourteenMetresPerSecond() {
    // 50.4 km/h is 14 m/s exactly; 49 km/h is 13.6.
    #expect(icon(reading(code: 95, wind: 50.4)) == .storm)
    #expect(icon(reading(code: 95, wind: 49)) == .thunder)
}

@Test func stormAlsoComesFromTwentyMetresPerSecondOfGusts() {
    #expect(icon(reading(code: 95, wind: 10, gusts: 72)) == .storm)      // 20 m/s
    #expect(icon(reading(code: 95, wind: 10, gusts: 71.9)) == .thunder)
}

@Test func windySnowIsABlizzardAndCalmSnowShowersKeepDayAndNight() {
    // Windy: ≥ 10 m/s of wind (36 km/h) or ≥ 15 m/s of gusts (54 km/h).
    #expect(icon(reading(code: 73, wind: 36)) == .blizzard)
    #expect(icon(reading(code: 86, wind: 5, gusts: 54)) == .blizzard)
    #expect(icon(reading(code: 85, wind: 35.9)) == .snowShowersDay)
    #expect(icon(reading(code: 86, isDay: false)) == .snowShowersNight)
    #expect(icon(reading(code: 77)) == .snow)
}

@Test func freezingCodesAreFreezingRain() {
    for code in [56, 57, 66, 67] { #expect(icon(reading(code: code)) == .freezingRain) }
}

@Test func wetCodesBetweenZeroAndTwoDegreesAreSleet() {
    #expect(icon(reading(code: 61, temperature: 0)) == .sleet)
    #expect(icon(reading(code: 80, temperature: 2)) == .sleet)
    #expect(icon(reading(code: 61, temperature: 2.1)) == .rain)
    #expect(icon(reading(code: 61, temperature: -0.1)) == .rain)
}

@Test func wetCodesOutsideTheSleetBandSplitByIntensity() {
    #expect(icon(reading(code: 53)) == .drizzle)
    #expect(icon(reading(code: 63)) == .rain)
    #expect(icon(reading(code: 65)) == .heavyRain)
    #expect(icon(reading(code: 82)) == .heavyRain)
    #expect(icon(reading(code: 81)) == .showersDay)
    #expect(icon(reading(code: 80, isDay: false)) == .showersNight)
}

@Test func fogAndRimeFog() {
    #expect(icon(reading(code: 45)) == .fog)
    #expect(icon(reading(code: 48)) == .rimeFog)
}

@Test func windyClearAndCloudySkiesShowTheWind() {
    #expect(icon(reading(code: 2, wind: 36)) == .windyDay)
    #expect(icon(reading(code: 0, isDay: false, wind: 36)) == .windyNight)
    #expect(icon(reading(code: 3, wind: 5, gusts: 54)) == .cloudWindy)
}

@Test func aClearDayAtThirtyIsHotAndAtMinusTenIsFrosty() {
    #expect(icon(reading(code: 0, temperature: 30)) == .hot)
    #expect(icon(reading(code: 1, temperature: -10)) == .frostyClear)
    #expect(icon(reading(code: 0, temperature: 29.9)) == .clearDay)
    // By night, and on a partly cloudy day, the rule does not hold.
    #expect(icon(reading(code: 2, temperature: 35)) == .partlyCloudyDay)
}

@Test func aClearNightIsTheMoonOfTheNight() {
    let fullMoon = Date(timeIntervalSince1970: 947_182_440 + 14.765 * 86_400)
    #expect(WeatherFacts.icon(for: reading(code: 0, isDay: false), at: fullMoon) == .moon4)
}

@Test func theRestSplitByCloudAndDaylight() {
    #expect(icon(reading(code: 0)) == .clearDay)
    #expect(icon(reading(code: 1)) == .mainlyClearDay)
    #expect(icon(reading(code: 1, isDay: false)) == .mainlyClearNight)
    #expect(icon(reading(code: 2, isDay: false)) == .partlyCloudyNight)
    #expect(icon(reading(code: 3)) == .cloudDay)
    #expect(icon(reading(code: 3, isDay: false)) == .cloudNight)
}

@Test func anUnknownCodeFallsBackToClear() {
    #expect(icon(reading(code: 42)) == .clearDay)
    #expect(icon(reading(code: 42, wind: 40)) == .windyDay)
}

// MARK: - §4.2 moon

@Test func theNewMoonOf2000IsPhaseZeroAndAFortnightLaterIsFull() {
    let newMoon = Date(timeIntervalSince1970: 947_182_440)          // 2000-01-06 18:14 UTC
    #expect(WeatherFacts.moonPhase(at: newMoon) == 0)
    #expect(WeatherFacts.moonPhase(at: newMoon.addingTimeInterval(14.765 * 86_400)) == 4)
    // Before the epoch the age wraps around rather than going negative.
    #expect(WeatherFacts.moonPhase(at: newMoon.addingTimeInterval(-3 * 86_400)) == 7)
}

// MARK: - The next sun event

private let rise0 = Date(timeIntervalSince1970: 1_790_133_381)
private let set0 = Date(timeIntervalSince1970: 1_790_177_183)
private let rise1 = Date(timeIntervalSince1970: 1_790_219_897)
private let set1 = Date(timeIntervalSince1970: 1_790_263_424)
private let day = reading(sunrises: [rise0, rise1], sunsets: [set0, set1])

@Test func afterSunsetTheNextEventIsTomorrowsSunrise() {
    #expect(WeatherFacts.nextSunEvent(after: set0.addingTimeInterval(1), in: day) == .rise(rise1))
}

@Test func beforeSunriseTheNextEventIsTodaysSunrise() {
    #expect(WeatherFacts.nextSunEvent(after: rise0.addingTimeInterval(-1), in: day) == .rise(rise0))
}

@Test func betweenSunriseAndSunsetTheNextEventIsTodaysSunset() {
    #expect(WeatherFacts.nextSunEvent(after: rise0, in: day) == .set(set0))
}

@Test func withoutADailyBlockThereIsNoSunEvent() {
    #expect(WeatherFacts.nextSunEvent(after: noon, in: reading()) == nil)
    #expect(WeatherFacts.nextSunEvent(after: rise1, in: day) == nil)
}

// MARK: - The rain window and the chart's hours

private func hour(_ offset: Int, _ pop: Int?, from start: Date = noon) -> WeatherReading.HourlyPoint {
    WeatherReading.HourlyPoint(
        time: start.addingTimeInterval(Double(offset) * 3_600), temperature: Double(offset),
        precipitationProbability: pop
    )
}

@Test func theRainChanceIsTheHighestOverThisHourAndTheNextTwo() {
    let series = reading(hourly: [hour(-1, 99), hour(0, 20), hour(1, 60), hour(2, 40), hour(3, 95)])
    // 12:40 lies in the 12:00 hour: the window is 12, 13 and 14.
    #expect(WeatherFacts.rainChance(at: noon.addingTimeInterval(40 * 60), in: series, timeZone: utc) == 60)
}

@Test func hoursWithoutAProbabilityAreSkippedAndNoneLeavesNoChance() {
    #expect(WeatherFacts.rainChance(at: noon, in: reading(hourly: [hour(0, nil), hour(1, 10)]), timeZone: utc) == 10)
    #expect(WeatherFacts.rainChance(at: noon, in: reading(hourly: [hour(0, nil), hour(3, 90)]), timeZone: utc) == nil)
    #expect(WeatherFacts.rainChance(at: noon, in: reading(), timeZone: utc) == nil)
}

@Test func theHourStartsOnTheClockOfTheZoneItIsReadIn() {
    // At 12:10 UTC, India (UTC+5:30) is at 17:40, whose hour began at 11:30
    // UTC: the 11:30 entry is in its window, not in the UTC one.
    let india = TimeZone(identifier: "Asia/Kolkata")!
    let now = noon.addingTimeInterval(10 * 60)
    let halfHours = reading(hourly: [hour(0, 70, from: noon.addingTimeInterval(-30 * 60)), hour(0, 20)])
    #expect(WeatherFacts.rainChance(at: now, in: halfHours, timeZone: india) == 70)
    #expect(WeatherFacts.rainChance(at: now, in: halfHours, timeZone: utc) == 20)
}

@Test func theChartIsTheCurrentHourAndTheNextTenInOrder() {
    let series = reading(hourly: (-2...14).reversed().map { hour($0, nil) })
    let hours = WeatherFacts.nextHours(at: noon.addingTimeInterval(59 * 60), in: series, timeZone: utc)
    #expect(hours.map(\.temperature) == (0...10).map(Double.init))
    // A short series draws fewer bars.
    #expect(WeatherFacts.nextHours(at: noon, in: reading(hourly: [hour(1, nil), hour(0, 5)]), timeZone: utc)
        .map(\.temperature) == [0, 1])
}

// MARK: - Wind

@Test func theArrowPointsWhereTheAirGoes() {
    #expect(WeatherFacts.arrow(fromDegrees: 225) == "⇗")
    #expect(WeatherFacts.arrow(fromDegrees: 0) == "⇓")
    #expect(WeatherFacts.arrow(fromDegrees: 90) == "⇐")
    // Halfway between two arrows rounds to the even one, as the mockup does.
    #expect(WeatherFacts.arrow(fromDegrees: 22.5) == "⇓")
    #expect(WeatherFacts.arrow(fromDegrees: 67.5) == "⇐")
    #expect(WeatherFacts.arrow(fromDegrees: 337.5) == "⇓")
}

@Test func windSpeedsConvertFromTheServicesKilometresPerHour() {
    #expect(WeatherFacts.metresPerSecond(kilometresPerHour: 36) == 10)
    #expect(WeatherFacts.speed(kilometresPerHour: 18, in: .metresPerSecond) == 5)
    #expect(WeatherFacts.speed(kilometresPerHour: 18, in: .kilometresPerHour) == 18)
    #expect(WeatherFacts.speed(kilometresPerHour: 40.2336, in: .milesPerHour) == 25)
    // 9 km/h is 2.5 m/s: half to even, as the mockup rounds.
    #expect(WeatherFacts.speed(kilometresPerHour: 9, in: .metresPerSecond) == 2)
}
