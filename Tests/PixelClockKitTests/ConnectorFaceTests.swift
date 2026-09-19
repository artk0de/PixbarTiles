import Foundation
import Testing
@testable import PixelClockKit

// A connector is two halves. `read()` goes out for a value, and its AWTRIX face
// draws that value without going anywhere. `produce()` joins the two, and it is
// what the AWTRIX session runs.

/// Reads a number and draws it, so the join can be seen without a real source.
private struct Numeral: Connector {
    let id = "numeral"
    let displayName = "Numeral"
    let defaultInterval: TimeInterval = 60
    let value: Int

    func read() async throws -> Int { value }

    var awtrixFace: AwtrixFace<Int> { AwtrixFace { AwtrixDelivery(text: "\($0)") } }
}

@Test func whatIsProducedIsWhatTheFaceDrawsOfWhatWasRead() async throws {
    #expect(try await Numeral(value: 42).produce().text == "42")
}

// MARK: - Weather

private let skyAtFourDegrees = Data("""
{"current":{"time":"2026-08-19T02:45","interval":900,"weather_code":61,
  "is_day":1,"precipitation":0.4,"temperature_2m":4.2,"wind_speed_10m":9.0}}
""".utf8)

@Test func theWeatherReadsTheSkyAndItsFaceDrawsIt() async throws {
    let transport = RecordingTransport()
    transport.body = skyAtFourDegrees
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport),
        location: { Coordinates(latitude: 55.7558, longitude: 37.6173) }
    )

    let reading = try await connector.read()
    let drawn = connector.awtrixFace.draw(reading)

    #expect(reading.code == 61)
    #expect(reading.temperature == 4.2)
    #expect(drawn == WeatherConnector.output(for: reading))
    #expect(drawn.text == "4°C")
    #expect(drawn.surface == .app(WeatherConnector.appName))
}

// MARK: - Claude usage

/// Answers with one fixed reading. Stands behind `ClaudeUsageReporting`, the
/// seam the Claude connector's `read()` calls whatever source is behind it.
private struct Reports: ClaudeUsageReporting {
    let reading: ClaudeUsageReading?
    func read() async throws -> ClaudeUsageReading? { reading }
}

@Test func theClaudeReadingIsTheReportersOwnAndItsFaceDrawsIt() async throws {
    let reported = ClaudeUsageReading(utilization: 42, resetsAt: nil)
    let connector = ClaudeUsageConnector(reporter: Reports(reading: reported))

    let reading = try await connector.read()

    #expect(reading == reported)
    #expect(connector.awtrixFace.draw(reading) == ClaudeUsageConnector.output(for: reading))
}

@Test func aClosedGateStopsTheClaudeReadBeforeAnythingIsDrawn() async {
    let connector = ClaudeUsageConnector(
        reporter: Reports(reading: ClaudeUsageReading(utilization: 42, resetsAt: nil)),
        showsNow: { false }
    )

    await #expect(throws: ClaudeUsageConnector.Failure.outOfFocus) {
        _ = try await connector.read()
    }
}

// MARK: - Anecdotes

private let oneAnecdote = """
<rss><channel><item>
<description><![CDATA[Звонок от курьера:<br>- Я подъехал...<br>- Но я вас не вижу...]]></description>
<guid>https://www.anekdot.ru/id/1/</guid>
</item></channel></rss>
"""

// Reading an anecdote is playing it: the read retires it, so a replay that
// draws from the History spends nothing.
@Test func readingAnAnecdoteRetiresItAndItsFaceDrawsTheBanner() async throws {
    let transport = RecordingTransport()
    transport.body = Data(oneAnecdote.utf8)
    let queue = AnecdoteQueue(
        storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("face-\(UUID().uuidString).json"),
        clipRoot: FileManager.default.temporaryDirectory,
        retention: 10 * 24 * 60 * 60
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let anecdote = try await connector.read()

    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(connector.awtrixFace.draw(anecdote) == connector.output(for: anecdote))
}
