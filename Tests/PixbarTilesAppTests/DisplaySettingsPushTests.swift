// Tests/PixbarTilesAppTests/DisplaySettingsPushTests.swift
import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// A display setting changed in a tile's settings window reaches the clock AT
// ONCE, and what reaches it is drawn with the new setting. The schedule's sleep
// is parked in every test here, so any delivery a test sees was made by the
// save itself — never by a poll.
//
// The connectors are the shipped ones, built by the very `ConnectorFactories`
// the live sessions are built from; the host in the slot builds each run's
// connector from the record it is handed, exactly as `UlanziClockHost` does,
// and keeps what the connector produced.

private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.5")

/// Builds the run's connector from the record the model hands it and keeps
/// the page that connector produced — the slot's own two steps, minus the
/// device.
private final class ProducingHost: ConnectorRunning, @unchecked Sendable {
    private let registry: ConnectorRegistry
    private let lock = NSLock()
    private var produced: [UlanziDelivery?] = []

    init(registry: ConnectorRegistry) {
        self.registry = registry
    }

    var deliveries: [UlanziDelivery?] { lock.withLock { produced } }

    func runOnce(tile: TileRecord) async -> RunResult {
        guard let connector = registry.connector(for: tile) else { return .failed("unknown") }
        let delivery = try? await connector.produceUlanzi()
        lock.withLock { produced.append(delivery) }
        return .delivered
    }

    func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
    func restoreDeviceState(borrowedBy tileId: String?) async {}
    var indicators: IndicatorCustody? { nil }
}

/// Answers per route, keyed by the last path component — z.ai asks two.
private final class RoutingTransport: Transport, @unchecked Sendable {
    private let answers: [String: Data]

    init(_ answers: [String: Data]) {
        self.answers = answers
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = answers[request.url?.lastPathComponent ?? ""]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil
        )!
        return (body ?? Data(), response)
    }
}

/// One fixed reading, so the page is drawn from it and never from a file.
private struct FixedClaude: ClaudeUsageReporting {
    let reading: ClaudeUsageReading?
    func read() async throws -> ClaudeUsageReading? { reading }
}

private let claudeReading = ClaudeUsageReading(
    utilization: 41, resetsAt: Date(timeIntervalSinceNow: 3 * 86_400),
    fiveHour: ClaudeUsageWindow(utilization: 91, resetsAt: Date(timeIntervalSinceNow: 2 * 3_600))
)

private let weatherBody = Data("""
{"current":{"time":1790171100,"interval":900,"weather_code":3,"is_day":1,"temperature_2m":18.0,"apparent_temperature":18.2,"wind_speed_10m":7.3,"wind_direction_10m":101,"wind_gusts_10m":20.2,"relative_humidity_2m":77,"uv_index":0.55,"precipitation":0.0},
 "hourly":{"time":[1790110800,1790114400,1790118000],"temperature_2m":[15.6,15.4,15.0],"precipitation_probability":[60,35,15]},
 "daily":{"time":[1790110800,1790197200],"temperature_2m_max":[18.3,20.9],"temperature_2m_min":[12.8,11.6],"sunrise":[1790133381,1790219897],"sunset":[1790177183,1790263424]}}
""".utf8)

private let zaiQuota = Data("""
{"data":{"level":"PRO","limits":[
  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12.4,"usage":800000000},
  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":34.5,"usage":900000000},
  {"type":"TIME_LIMIT","percentage":7,"currentValue":7,"usage":100}
]}}
""".utf8)

private let zaiUsage = Data("""
{"data":{"totalUsage":{"totalModelCallCount":42,"totalTokensUsage":1234567}}}
""".utf8)

private let githubBody = Data("""
{"data":{"repository":{
  "nameWithOwner":"artk0de/tea-rags","stargazerCount":1234,"forkCount":45,
  "pullRequests":{"totalCount":3},"stargazers":{"edges":[]},"forks":{"nodes":[]},"openPRs":{"nodes":[]}
}}}
""".utf8)

private struct NoSnapshots: GitHubSnapshotStoring {
    func snapshot(for tile: TileKey) -> GitHubSnapshot? { nil }
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {}
}

private let circle = CodeUsage.Parameters(resetEvery: 10, resetAfter: 80, layout: .circle)

@MainActor
@Suite struct DisplaySettingsPushTests {
    /// A model whose TC002 slot runs the shipped factories' connectors.
    private func makeModel(
        tiles: [TileRecord], transport: any Transport, secrets: any SecretStoring = MemorySecretStore()
    ) -> (AppModel, ProducingHost) {
        let defaults = UserDefaults(suiteName: "display-push-\(UUID().uuidString)")!
        let factories = ConnectorFactories(
            transport: transport, defaults: defaults, secrets: secrets,
            weather: OpenMeteoSource(transport: transport), anecdotes: StubConnector(id: "anecdotes"),
            claudeReporter: { FixedClaude(reading: claudeReading) }
        )
        let own = factories.registry(for: desk)
        let host = ProducingHost(registry: own)
        let app = testModel(
            connectors: [
                WeatherConnector(
                    source: OpenMeteoSource(transport: transport),
                    location: { .default }, config: { WeatherTileConfig(place: .default) }
                ),
                ClaudeUsageConnector(reporter: FixedClaude(reading: nil)),
            ] + ConnectorFactories.namingInstances(transport: transport),
            defaults: defaults, clocks: [desk], tiles: tiles, secrets: secrets,
            sessions: [desk.id: host], makeClockRegistry: { _ in own }
        )
        return (app, host)
    }

    private func record(_ key: TileKey, _ config: TileConfig) -> TileRecord {
        TileRecord(key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900), config: config)
    }

    private func opened(_ app: AppModel, _ key: TileKey) async -> TileSettingsModel {
        let subject = TileSettingsModel(model: app, debounce: 0)
        app.openDetail(for: key)
        _ = await waitUntil { subject.key == key }
        return subject
    }

    @Test func aWeatherLayoutChangeIsOnTheClockAtOnce() async throws {
        let key = TileKey(clockId: desk.id, connectorId: WeatherConnector.appName)
        let before = WeatherTileConfig(place: .default, layout: .anchor)
        let transport = StubTransport(body: weatherBody)
        let (app, host) = makeModel(tiles: [record(key, .weather(before))], transport: transport)
        let subject = await opened(app, key)

        subject.setLayout(.pages)

        #expect(await waitUntil { host.deliveries.count == 1 })
        var changed = before
        changed.layout = .pages
        let after = changed
        let expected = try await WeatherConnector(
            source: OpenMeteoSource(transport: transport), location: { .default }, config: { after }
        ).produceUlanzi()
        let stale = try await WeatherConnector(
            source: OpenMeteoSource(transport: transport), location: { .default }, config: { before }
        ).produceUlanzi()
        let delivered = try #require(host.deliveries.last ?? nil)
        #expect(delivered.scene == expected?.scene)
        #expect(delivered.scene != stale?.scene)
    }

    @Test func aClaudeLayoutChangeIsOnTheClockAtOnce() async throws {
        let key = TileKey(clockId: desk.id, connectorId: ClaudeUsageConnector.id)
        let (app, host) = makeModel(
            tiles: [record(key, .claude(ClaudeTileConfig()))], transport: StubTransport()
        )
        let subject = await opened(app, key)

        subject.setParameters(circle)

        #expect(await waitUntil { host.deliveries.count == 1 })
        let expected = try await ClaudeUsageConnector(
            reporter: FixedClaude(reading: claudeReading), parameters: { circle }
        ).produceUlanzi()
        let stale = try await ClaudeUsageConnector(
            reporter: FixedClaude(reading: claudeReading), parameters: { .standard }
        ).produceUlanzi()
        let delivered = try #require(host.deliveries.last ?? nil)
        #expect(delivered.scene == expected?.scene)
        #expect(delivered.scene != stale?.scene)
    }

    @Test func aZaiLayoutChangeIsOnTheClockAtOnce() async throws {
        let key = TileKey(clockId: desk.id, connectorId: ZaiUsageConnector.connectorId)
        let secrets = MemorySecretStore()
        try secrets.save("sk-test", for: .tile(key))
        let transport = RoutingTransport(["limit": zaiQuota, "model-usage": zaiUsage])
        let (app, host) = makeModel(
            tiles: [record(key, .zai(ZaiTileConfig(keyAccount: ZaiTileConfig.account(for: key))))],
            transport: transport, secrets: secrets
        )
        let subject = await opened(app, key)

        subject.setParameters(circle)

        #expect(await waitUntil { host.deliveries.count == 1 })
        func page(_ parameters: CodeUsage.Parameters) async throws -> UlanziDelivery? {
            try await ZaiUsageConnector(
                source: ZaiUsageAPI(transport: transport, key: { "sk-test" }),
                parameters: { parameters }
            ).produceUlanzi()
        }
        let delivered = try #require(host.deliveries.last ?? nil)
        #expect(delivered.scene == (try await page(circle))?.scene)
        #expect(delivered.scene != (try await page(.standard))?.scene)
    }

    @Test func aGitHubMainWatchChangeIsOnTheClockAtOnce() async throws {
        let key = TileKey(clockId: desk.id, connectorId: GitHubConnector.connectorId, instance: "artk0de/tea-rags")
        let secrets = MemorySecretStore()
        try secrets.save("github_pat", for: .connector(GitHubConnector.connectorId))
        let transport = StubTransport(body: githubBody)
        let before = GitHubTileConfig(repo: "artk0de/tea-rags")
        let (app, host) = makeModel(
            tiles: [record(key, .github(before))], transport: transport, secrets: secrets
        )
        let subject = await opened(app, key)
        var after = before
        after.mainWatch = .prs

        subject.setGitHubConfig(after)

        #expect(await waitUntil { host.deliveries.count == 1 })
        func page(_ config: GitHubTileConfig) async throws -> UlanziDelivery? {
            try await GitHubConnector(
                tile: record(key, .github(config)),
                source: GitHubAPI(transport: transport, token: { "github_pat" }),
                snapshots: NoSnapshots()
            ).produceUlanzi()
        }
        let delivered = try #require(host.deliveries.last ?? nil)
        #expect(delivered.scene == (try await page(after))?.scene)
        #expect(delivered.scene != (try await page(before))?.scene)
    }
}

// MARK: - When a save pushes, and when it does not

@MainActor
@Suite struct DisplaySettingsPushRuleTests {
    private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.5")

    private var claude: any Connector {
        ClaudeUsageConnector(reporter: FixedClaude(reading: nil))
    }

    private func claudeKey() -> TileKey {
        TileKey(clockId: kitchen.id, connectorId: ClaudeUsageConnector.id)
    }

    private func makeModel(paused: Bool = false, host: SpyHost) -> AppModel {
        testModel(
            connectors: [claude], clocks: [kitchen],
            tiles: [TileRecord(
                key: claudeKey(),
                policy: TilePolicyRecord(isPaused: paused, refreshSeconds: 900),
                config: .claude(ClaudeTileConfig())
            )],
            sessions: [kitchen.id: host]
        )
    }

    private func runs(_ host: SpyHost) -> Int {
        host.calls.filter { $0 == "run:\(ClaudeUsageConnector.id)" }.count
    }

    // The save is the delivery: the schedule's sleep is parked, so the run
    // the host sees can only be the one the save asked for.
    @Test func aDisplaySettingSaveRunsTheTileWithoutWaitingForThePoll() async throws {
        let host = SpyHost()
        let app = makeModel(host: host)
        let policy = try #require(app.storedPolicy(of: claudeKey()))

        _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig(parameters: circle)))

        #expect(await waitUntil { runs(host) == 1 })
    }

    // Only the look moves the clock. The interval slider rebuilds the
    // schedule and must not touch the clock.
    @Test func aPolicyOnlySaveDoesNotRunTheTile() async throws {
        let host = SpyHost()
        let app = makeModel(host: host)
        var policy = try #require(app.storedPolicy(of: claudeKey()))
        policy.refreshSeconds = 120

        _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig()))

        try await Task.sleep(for: .milliseconds(200))
        #expect(runs(host) == 0)
    }

    // A paused tile keeps its look for when it is switched back on.
    @Test func aPausedTilesSaveDoesNotRunIt() async throws {
        let host = SpyHost()
        let app = makeModel(paused: true, host: host)
        let policy = try #require(app.storedPolicy(of: claudeKey()))

        _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig(parameters: circle)))

        try await Task.sleep(for: .milliseconds(200))
        #expect(runs(host) == 0)
    }

    /// The spy, as a clock that can switch pages: the settings window's
    /// follow only moves a clock that can.
    private final class PagedSpy: ConnectorRunning, ClockPageShowing, @unchecked Sendable {
        let spy: SpyHost
        init(_ spy: SpyHost) { self.spy = spy }
        func page(forTile tileId: String) async throws -> String? { "p-\(tileId)" }
        func currentPage() async throws -> String? { nil }
        func showPage(_ page: String) async throws {}
        func runOnce(tile: TileRecord) async -> RunResult { await spy.runOnce(tile: tile) }
        func maintain(tile: TileRecord) async -> MaintenanceResult { await spy.maintain(tile: tile) }
        func deliver(_ output: AwtrixDelivery) async -> RunResult { await spy.deliver(output) }
        func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
        func restoreDeviceState(borrowedBy tileId: String?) async {
            await spy.restoreDeviceState(borrowedBy: tileId)
        }
        var indicators: IndicatorCustody? { nil }
    }

    // Out of its hours the tile is off the clock; its settings window puts it
    // on, a look changed there reaches the clock, and closing takes it off.
    @Test func aTileOutOfItsHoursIsOnTheClockWhileItsSettingsAreOpen() async throws {
        let host = SpyHost()
        let app = testModel(
            connectors: [claude], clocks: [kitchen],
            tiles: [TileRecord(
                key: claudeKey(), policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900),
                config: .claude(ClaudeTileConfig())
            )],
            sessions: [kitchen.id: PagedSpy(host)]
        )
        var policy = try #require(app.storedPolicy(of: claudeKey()))
        // Working hours that start an hour from now: off the clock at present.
        let hour = Calendar.current.component(.hour, from: Date())
        policy.window = .active(HourWindow(startHour: (hour + 1) % 24, endHour: (hour + 2) % 24))
        _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig()))

        app.openDetail(for: claudeKey())
        #expect(await waitUntil { runs(host) == 1 })
        _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig(parameters: circle)))
        #expect(await waitUntil { runs(host) == 2 })

        app.closeDetail()
        #expect(await waitUntil { host.calls.contains("restore:\(ClaudeUsageConnector.id)") })
    }

    // A burst of changes while a push is on the wire is ONE more push, made
    // after it — so the last page on the clock is drawn from the last save,
    // never overtaken by a slower run with an older one.
    @Test func changesMadeDuringAPushAreOneMorePushAfterIt() async throws {
        let gate = Gate()
        let host = SpyHost(parkInRun: gate)
        let app = makeModel(host: host)
        let policy = try #require(app.storedPolicy(of: claudeKey()))

        _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig(parameters: circle)))
        #expect(await waitUntil { gate.enteredCount == 1 })
        for every: TimeInterval in [30, 60] {
            var tuned = circle
            tuned.resetEvery = every
            _ = app.saveTile(key: claudeKey(), policy: policy, config: .claude(ClaudeTileConfig(parameters: tuned)))
        }
        gate.open()

        #expect(await waitUntil { runs(host) == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(runs(host) == 2)
    }
}
