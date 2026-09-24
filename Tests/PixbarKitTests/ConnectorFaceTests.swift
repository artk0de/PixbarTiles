import Foundation
import Testing
@testable import PixbarKit

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
    let config = WeatherTileConfig(place: Coordinates(latitude: 55.7558, longitude: 37.6173))
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport),
        location: { Coordinates(latitude: 55.7558, longitude: 37.6173) },
        config: { config }
    )

    let reading = try await connector.read()
    let drawn = connector.awtrixFace.draw(reading)

    #expect(reading.code == 61)
    #expect(reading.temperature == 4.2)
    #expect(drawn == WeatherConnector.output(for: reading, config: config))
    #expect(drawn.text == "4°C")
    #expect(drawn.surface == .app(WeatherConnector.appName))
}

// MARK: - Claude usage

/// Answers with one fixed reading, on each vendor's own seam — the protocol
/// its connector's `read()` calls whatever source is behind it.
private struct ReportsZai: ZaiUsageReporting {
    let reading: ZaiUsageReading?
    func read() async throws -> ZaiUsageReading? { reading }
}

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

// MARK: - One page, two vendors

/// A Claude reading carrying every figure a status-line document can name.
private let claudeReading = ClaudeUsageReading(
    utilization: 41,
    resetsAt: nil,
    fiveHour: ClaudeUsageWindow(utilization: 23, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
    contextWindow: 8,
    observedAt: nil
)

// The one thing the substrate is FOR: both tiles draw the same page, and what
// a vendor is allowed to differ by is its mark and its colours. Written as an
// assertion rather than as a comment, because "they are the same" is a claim
// that decays silently — the AWTRIX pages had already drifted into two shapes
// before anybody noticed.
@Test func bothVendorsDrawOnePageDifferingOnlyInMarkAndColour() {
    let reading = CodeUsage.Reading(
        fiveHour: CodeUsage.Window(percent: 23, resetsAt: nil),
        weekly: CodeUsage.Window(percent: 41, resetsAt: nil)
    )
    let claude = CodeUsage.Tile.awtrix(reading, vendor: .claude)
    let zai = CodeUsage.Tile.awtrix(reading, vendor: .zai)

    // Same figure, same bar, same surface kind, same lifetime.
    #expect(claude?.text == zai?.text)
    #expect(claude?.progress?.percent == zai?.progress?.percent)
    #expect(claude?.scene.lifetime == zai?.scene.lifetime)
    // Differing in exactly the two things a vendor owns.
    #expect(claude?.color == CodeUsage.Vendor.claude.brand)
    #expect(zai?.color == CodeUsage.Vendor.zai.brand)
    #expect(claude?.icon == CodeUsage.Vendor.claude.icon)
    #expect(zai?.icon == CodeUsage.Vendor.zai.icon)
    #expect(claude?.icon != zai?.icon)
}

// The WEEK is the figure, on both tiles. A five-hour window empties and
// refills several times inside one week, so a page showing it would swing
// between readings that are each true and mean nothing together.
@Test func theHeadlineIsTheWeekNotTheFiveHourWindow() {
    let page = ClaudeUsageConnector.output(for: claudeReading)

    #expect(page.text == "41%")
    #expect(page.progress?.percent == 41)
}

// z.ai used to join its windows into one line — `"84% 52%"` — with no mark and
// no bar. It draws the substrate's page now.
@Test func theZaiPageIsTheSameShapeAsClaudes() {
    let reading = ZaiUsageReading(
        limits: ZaiUsageLimits(
            fiveHour: ZaiUsageWindow(percentUsed: 84),
            weekly: ZaiUsageWindow(percentUsed: 52)
        ),
        totals: ZaiUsageTotals()
    )
    let page = ZaiUsageConnector.output(for: reading)

    #expect(page.text == "52%")
    #expect(page.progress?.percent == 52)
    #expect(page.icon == CodeUsage.Vendor.zai.icon)
    #expect(page.color == ZaiUsage.brandColour)
}

// A reading that names no window at all is no delivery: the app carries a
// lifetime, so the clock drops the tile by itself rather than being fed a
// figure nothing stands behind.
@Test func aReadingWithNoWindowIsNoPage() {
    #expect(CodeUsage.Tile.awtrix(
        CodeUsage.Reading(fiveHour: nil, weekly: nil), vendor: .claude
    ) == nil)
}

@Test func theRunRefusesAReadingWithNoWindow() async {
    let blank = ZaiUsageReading(limits: ZaiUsageLimits(), totals: ZaiUsageTotals())
    let connector = ZaiUsageConnector(source: ReportsZai(reading: blank))

    await #expect(throws: ZaiUsageConnector.Failure.noReading) {
        try await connector.produce()
    }
}

@Test func theRunDeliversTheFace() async throws {
    let connector = ClaudeUsageConnector(reporter: Reports(reading: claudeReading))

    #expect(try await connector.produce() == ClaudeUsageConnector.output(for: claudeReading))
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
