import Foundation
import Testing
@testable import AwtrixKit

/// The shape the live API answers with, verified against it: a `current`
/// object carrying its own update interval beside the readings.
private func body(
    code: Int = 3, isDay: Int = 1, temperature: Double = 18.6,
    precipitation: Double = 0, wind: Double = 10.5, interval: Int = 900
) -> Data {
    Data("""
    {"latitude":55.75,"longitude":37.625,"utc_offset_seconds":0,
     "current_units":{"time":"iso8601","interval":"seconds","weather_code":"wmo code"},
     "current":{"time":"2026-08-19T02:45","interval":\(interval),"weather_code":\(code),
       "is_day":\(isDay),"precipitation":\(precipitation),
       "temperature_2m":\(temperature),"wind_speed_10m":\(wind)}}
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
    for field in ["weather_code", "is_day", "precipitation", "temperature_2m", "wind_speed_10m"] {
        #expect(url.contains(field), "the request does not ask for \(field)")
    }
}

@Test func theSourceDecodesTheCurrentBlockTheApiAnswersWith() async throws {
    let transport = RecordingTransport()
    transport.body = body(code: 61, isDay: 0, temperature: -3.4, precipitation: 1.2, wind: 22)
    let source = OpenMeteoSource(transport: transport)

    let reading = try await source.reading(at: moscow)

    #expect(reading.code == 61)
    // `is_day` arrives as 1 or 0, not as a JSON boolean.
    #expect(reading.isDay == false)
    #expect(reading.temperature == -3.4)
    #expect(reading.precipitation == 1.2)
    #expect(reading.windSpeed == 22)
    #expect(reading.interval == 900)
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
