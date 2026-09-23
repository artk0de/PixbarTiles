import Foundation
import Testing
@testable import PixelClockKit

/// The shape the live API answers with, verified against it: a `current`
/// object carrying its own update interval beside the readings.
private func body(
    code: Int = 3, isDay: Int = 1, temperature: Double = 18.6, apparent: Double? = 15.4,
    precipitation: Double = 0, wind: Double = 10.5, interval: Int = 900
) -> Data {
    // Omitted rather than sent as null when there is none, because that is how
    // a field the service stopped answering with would actually arrive.
    let felt = apparent.map { ",\"apparent_temperature\":\($0)" } ?? ""
    return Data("""
    {"latitude":55.75,"longitude":37.625,"utc_offset_seconds":0,
     "current_units":{"time":"iso8601","interval":"seconds","weather_code":"wmo code"},
     "current":{"time":"2026-08-19T02:45","interval":\(interval),"weather_code":\(code),
       "is_day":\(isDay),"precipitation":\(precipitation),
       "temperature_2m":\(temperature)\(felt),"wind_speed_10m":\(wind)}}
    """.utf8)
}

private let moscow = Coordinates(latitude: 55.7558, longitude: 37.6173)
private let berlin = Coordinates(latitude: 52.52, longitude: 13.405)

/// A clock a test turns by hand.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 1_700_000_000)

    var now: @Sendable () -> Date { { self.lock.withLock { self.moment } } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { moment = moment.addingTimeInterval(seconds) }
    }
}

@Test func theSourceAsksOpenMeteoForTheFieldsTheMappingNeeds() async throws {
    let transport = RecordingTransport()
    transport.body = body()
    let source = OpenMeteoSource(transport: transport)

    _ = try await source.reading(at: moscow)

    let request = try #require(transport.requests.first)
    let url = try #require(request.url?.absoluteString)
    #expect(request.httpMethod == "GET")
    #expect(url.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
    #expect(url.contains("latitude=55.7558"))
    #expect(url.contains("longitude=37.6173"))
    // No key and no signup, so there is nothing else to send. What the query
    // must carry is every field the theme and the reading are built from.
    for field in [
        "weather_code", "is_day", "precipitation", "temperature_2m", "wind_speed_10m",
        "apparent_temperature",
    ] {
        #expect(url.contains(field), "the request does not ask for \(field)")
    }
}

@Test func theSourceDecodesTheCurrentBlockTheApiAnswersWith() async throws {
    let transport = RecordingTransport()
    transport.body = body(
        code: 61, isDay: 0, temperature: -3.4, apparent: -9.1, precipitation: 1.2, wind: 22
    )
    let source = OpenMeteoSource(transport: transport)

    let reading = try await source.reading(at: moscow)

    #expect(reading.code == 61)
    // `is_day` arrives as 1 or 0, not as a JSON boolean.
    #expect(reading.isDay == false)
    #expect(reading.temperature == -3.4)
    // Two quantities, not one rounded off the other: -3.4 in a 22 km/h wind is
    // -9.1 to stand in, and the second is what the colour is chosen from.
    #expect(reading.apparentTemperature == -9.1)
    #expect(reading.precipitation == 1.2)
    #expect(reading.windSpeed == 22)
    #expect(reading.interval == 900)
}

// Optional for the reason `interval` is: a response that stops carrying a field
// has to read as "no answer for that" rather than fail the whole poll. The air
// temperature is still worth showing, and it is still what the digits say.
@Test func aResponseWithoutTheApparentTemperatureIsStillAReading() async throws {
    let transport = RecordingTransport()
    transport.body = body(temperature: 18.6, apparent: nil)
    let source = OpenMeteoSource(transport: transport)

    let reading = try await source.reading(at: moscow)

    #expect(reading.apparentTemperature == nil)
    #expect(reading.temperature == 18.6)
}

@Test func theSourceIsNotPolledFasterThanItsOwnInterval() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body()
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    clock.advance(899)
    _ = try await source.reading(at: moscow)

    // One request, not two: the weather does not move faster than the API's own
    // cadence, and this is a free public service.
    #expect(transport.requests.count == 1)

    clock.advance(2)
    _ = try await source.reading(at: moscow)

    #expect(transport.requests.count == 2)
}

// "Its own", literally: the cadence comes off the response rather than out of a
// constant here, so an API that slows down is obeyed rather than hammered.
@Test func theIntervalIsTheOneTheResponseCarriesRatherThanAConstant() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(interval: 1_800)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    clock.advance(1_000)
    _ = try await source.reading(at: moscow)

    // A thousand seconds is past the shipped floor and inside what this
    // response asked for.
    #expect(OpenMeteoSource.defaultInterval < 1_000)
    #expect(transport.requests.count == 1)
}

@Test func aCachedReadingIsTheOneHandedBackRatherThanARefetch() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(code: 71, temperature: -8)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    let first = try await source.reading(at: moscow)
    transport.body = body(code: 0, temperature: 30)
    clock.advance(60)
    let second = try await source.reading(at: moscow)

    #expect(second == first)
    #expect(second.code == 71)
}

// The location is a setting the user can edit, and a cache that ignored it
// would keep answering about the place they just left for a quarter of an hour.
@Test func movingTheLocationRefetchesRatherThanAnsweringAboutTheOldPlace() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(code: 71)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    transport.body = body(code: 0)
    let moved = try await source.reading(at: berlin)

    #expect(transport.requests.count == 2)
    #expect(moved.code == 0)
}

@Test func aServerErrorIsReportedRatherThanDecodedAsWeather() async {
    let transport = RecordingTransport()
    transport.status = 503
    transport.body = Data("<html>maintenance</html>".utf8)
    let source = OpenMeteoSource(transport: transport)

    await #expect(throws: WeatherError.http(status: 503)) {
        _ = try await source.reading(at: moscow)
    }
}

// A failed fetch must not be remembered as a reading, or one outage would be
// served for the whole of the next interval.
@Test func aFailedFetchLeavesNothingCachedToServe() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.status = 500
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try? await source.reading(at: moscow)
    transport.status = 200
    transport.body = body(code: 61)
    let recovered = try await source.reading(at: moscow)

    #expect(transport.requests.count == 2)
    #expect(recovered.code == 61)
}

// MARK: - One answer per place

// Two weather tiles at two places, polled in turn. Held in one slot, each poll
// evicted the other place's answer and every run went to the network.
@Test func twoPlacesPolledInTurnAreEachAnsweredFromTheirOwnCache() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(code: 71)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    transport.body = body(code: 0)
    _ = try await source.reading(at: berlin)
    clock.advance(60)
    let moscowAgain = try await source.reading(at: moscow)
    let berlinAgain = try await source.reading(at: berlin)

    #expect(transport.requests.count == 2)
    #expect(moscowAgain.code == 71)
    #expect(berlinAgain.code == 0)
}

@Test func eachPlaceAgesOnItsOwnInterval() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body()
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    clock.advance(500)
    _ = try await source.reading(at: berlin)
    clock.advance(401)
    _ = try await source.reading(at: moscow)
    _ = try await source.reading(at: berlin)

    // Moscow's 900 seconds are up and Berlin's are not.
    #expect(transport.requests.count == 3)
    #expect(transport.requests.last?.url?.absoluteString.contains("latitude=55.7558") == true)
}

@Test func aFailedFetchForOnePlaceLeavesAnotherPlacesAnswerStanding() async throws {
    let clock = Clock()
    let transport = RecordingTransport()
    transport.body = body(code: 71)
    let source = OpenMeteoSource(transport: transport, now: clock.now)

    _ = try await source.reading(at: moscow)
    transport.status = 500
    _ = try? await source.reading(at: berlin)
    let moscowAgain = try await source.reading(at: moscow)

    #expect(transport.requests.count == 2)
    #expect(moscowAgain.code == 71)
}

// MARK: - The wider request: the face's day, its hours and its wind

/// A live answer to the wider request, trimmed to three hours and two days:
/// `timeformat=unixtime` makes every time an epoch second, and the daily
/// buckets are the place's local days.
private let wideBody = Data("""
{"current":{"time":1790171100,"interval":900,"weather_code":3,"is_day":1,"temperature_2m":18.0,"apparent_temperature":18.2,"wind_speed_10m":7.3,"wind_direction_10m":101,"wind_gusts_10m":20.2,"relative_humidity_2m":77,"uv_index":0.55,"precipitation":0.0},
 "hourly":{"time":[1790110800,1790114400,1790118000],"temperature_2m":[15.6,15.4,15.0],"precipitation_probability":[60,35,15]},
 "daily":{"time":[1790110800,1790197200],"temperature_2m_max":[18.3,20.9],"temperature_2m_min":[12.8,11.6],"sunrise":[1790133381,1790219897],"sunset":[1790177183,1790263424]}}
""".utf8)

@Test func theSourceAsksForTheWindTheDayAndTheHours() async throws {
    let transport = RecordingTransport()
    transport.body = wideBody
    let source = OpenMeteoSource(transport: transport)

    _ = try await source.reading(at: moscow)

    let request = try #require(transport.requests.first)
    let url = try #require(request.url)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    let current = try #require(value("current")).split(separator: ",").map(String.init)
    for field in ["wind_direction_10m", "wind_gusts_10m", "uv_index"] {
        #expect(current.contains(field), "current does not ask for \(field)")
    }
    #expect(value("hourly") == "temperature_2m,precipitation_probability")
    #expect(value("daily") == "temperature_2m_max,temperature_2m_min,sunrise,sunset")
    // Epochs, so no date string has to be parsed in a zone the app has to
    // guess; the place's own days, so "today" is the place's today.
    #expect(value("timeformat") == "unixtime")
    #expect(value("timezone") == "auto")
    #expect(value("forecast_days") == "2")
}

@Test func theWiderAnswerDecodesEveryNewField() async throws {
    let transport = RecordingTransport()
    transport.body = wideBody
    let source = OpenMeteoSource(transport: transport)

    let reading = try await source.reading(at: moscow)

    #expect(reading.windSpeed == 7.3)                 // still km/h, as the service answers
    #expect(reading.windDirection == 101)
    #expect(reading.windGusts == 20.2)
    #expect(reading.uvIndex == 0.55)
    #expect(reading.relativeHumidity == 77)
    #expect(reading.todayHigh == 18.3)
    #expect(reading.todayLow == 12.8)
    #expect(reading.sunrises == [1_790_133_381, 1_790_219_897].map { Date(timeIntervalSince1970: $0) })
    #expect(reading.sunsets == [1_790_177_183, 1_790_263_424].map { Date(timeIntervalSince1970: $0) })
    #expect(reading.hourly == [
        WeatherReading.HourlyPoint(
            time: Date(timeIntervalSince1970: 1_790_110_800), temperature: 15.6, precipitationProbability: 60),
        WeatherReading.HourlyPoint(
            time: Date(timeIntervalSince1970: 1_790_114_400), temperature: 15.4, precipitationProbability: 35),
        WeatherReading.HourlyPoint(
            time: Date(timeIntervalSince1970: 1_790_118_000), temperature: 15.0, precipitationProbability: 15),
    ])
}

// Each new field drops its own detail, never the poll: an answer carrying
// the `current` block alone is the reading it always was.
@Test func anAnswerWithTheCurrentBlockAloneLeavesEveryNewFieldEmpty() async throws {
    let transport = RecordingTransport()
    transport.body = body()
    let source = OpenMeteoSource(transport: transport)

    let reading = try await source.reading(at: moscow)

    #expect(reading.code == 3)
    #expect(reading.windDirection == nil)
    #expect(reading.windGusts == nil)
    #expect(reading.uvIndex == nil)
    #expect(reading.todayHigh == nil)
    #expect(reading.todayLow == nil)
    #expect(reading.sunrises.isEmpty)
    #expect(reading.sunsets.isEmpty)
    #expect(reading.hourly.isEmpty)
}

// The hourly arrays are parallel; a series whose arrays disagree in length is
// read as far as all of them reach, and a missing probability is "no answer
// for that hour" rather than a zero.
@Test func hourlyArraysAreZippedToTheShortestAndANullProbabilityStaysNil() async throws {
    let transport = RecordingTransport()
    transport.body = Data("""
    {"current":{"interval":900,"weather_code":0,"is_day":1,"temperature_2m":1,"precipitation":0,"wind_speed_10m":0},
     "hourly":{"time":[100,3700,7300],"temperature_2m":[1.5,2.5],"precipitation_probability":[null,40,50]}}
    """.utf8)
    let source = OpenMeteoSource(transport: transport)

    let reading = try await source.reading(at: moscow)

    #expect(reading.hourly == [
        WeatherReading.HourlyPoint(time: Date(timeIntervalSince1970: 100), temperature: 1.5, precipitationProbability: nil),
        WeatherReading.HourlyPoint(time: Date(timeIntervalSince1970: 3_700), temperature: 2.5, precipitationProbability: 40),
    ])
}
