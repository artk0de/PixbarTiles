// Tests/PixelClockKitTests/ZaiUsageConnectorTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The connector is two halves, like every other: the source asks the two
// dashboard routes over the injected transport, and the faces draw the reading
// without going anywhere. The routes are never exercised against the network —
// a routing transport answers per path, and the requests themselves are what
// the tests pin.

/// Answers each route with its own canned body, and records what was asked.
private final class RoutingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var answers: [String: (status: Int, body: Data)] = [:]

    init(answers: [String: (status: Int, body: Data)]) {
        self.answers = answers
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    /// The answer keyed by the last path component, so a test can fail one
    /// route while the other answers.
    func set(_ status: Int, body: Data, for path: String) {
        lock.withLock { answers[path] = (status, body) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // One acquisition, released before the response is built — never held
        // across a suspension point.
        let answer = lock.withLock { () -> (status: Int, body: Data)? in
            recorded.append(request)
            return answers[request.url?.lastPathComponent ?? ""]
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer?.status ?? 404,
            httpVersion: nil, headerFields: nil
        )!
        return (answer?.body ?? Data(), response)
    }
}

private let quotaBody = Data("""
{"data":{"level":"PRO","limits":[
  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12.4,"usage":800000000},
  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":34.5,"usage":900000000},
  {"type":"TIME_LIMIT","percentage":7,"currentValue":7,"usage":100}
]}}
""".utf8)

private let usageBody = Data("""
{"data":{"totalUsage":{"totalModelCallCount":42,"totalTokensUsage":1234567}}}
""".utf8)

@Suite struct ZaiUsageSourceTests {
    private let moment = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeSource(
        _ transport: RoutingTransport, host: ZaiUsageAPI.Host = .zai,
        key: String? = "sk-test"
    ) -> ZaiUsageAPI {
        ZaiUsageAPI(
            transport: transport, host: host,
            key: { key },
            now: { self.moment }
        )
    }

    private func makeTransport() -> RoutingTransport {
        RoutingTransport(answers: [
            "model-usage": (200, usageBody),
            "limit": (200, quotaBody),
        ])
    }

    @Test func theReadingIsBothRoutesMerged() async throws {
        let transport = makeTransport()

        let reading = try #require(try await makeSource(transport).read())

        #expect(reading.level == "PRO")
        #expect(reading.fiveHour?.percentUsed == 12)
        #expect(reading.weekly?.percentUsed == 35)
        #expect(reading.mcpMonthly?.percentUsed == 7)
        #expect(reading.totalModelCalls == 42)
        #expect(reading.totalTokens == 1_234_567)
        #expect(reading.observedAt == moment)
    }

    /// The key goes over as the dashboard's own XHR sends it: raw, with no
    /// Bearer scheme. A Bearer prefix would authenticate as nobody.
    @Test func theKeyRidesRawWithNoBearerScheme() async throws {
        let transport = makeTransport()

        _ = try await makeSource(transport).read()

        for request in transport.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "sk-test")
        }
    }

    @Test func bothRoutesAreAskedOnTheConfiguredHost() async throws {
        let transport = makeTransport()

        _ = try await makeSource(transport).read()

        #expect(transport.requests.count == 2)
        let paths = transport.requests.compactMap { $0.url?.path }
        #expect(paths.contains("/api/monitor/usage/model-usage"))
        #expect(paths.contains("/api/monitor/usage/quota/limit"))
        #expect(transport.requests.allSatisfy { $0.url?.host == "api.z.ai" })
    }

    /// Zhipu plans are served by the other host; the routes are the same.
    @Test func aZhipuPlanAsksTheZhipuHost() async throws {
        let transport = makeTransport()

        _ = try await makeSource(transport, host: .zhipu).read()

        #expect(transport.requests.allSatisfy { $0.url?.host == "open.bigmodel.cn" })
    }

    /// The model-usage answer is over a time range, and the window is the
    /// trailing seven days ending now — the window the community tracker asks
    /// by default.
    @Test func theModelUsageRouteNamesItsWindow() async throws {
        let transport = makeTransport()

        _ = try await makeSource(transport).read()

        let request = try #require(
            transport.requests.first { $0.url?.path == "/api/monitor/usage/model-usage" }
        )
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        // An independent reader, not the writer: if the two ever drift apart,
        // this parse is the one that stops agreeing first.
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = .current
        reader.dateFormat = ZaiUsageAPI.dateFormat
        #expect(try #require(reader.date(from: query["startTime"] ?? ""))
            == Calendar.current.startOfDay(for: moment).addingTimeInterval(-7 * 86_400))
        #expect(try #require(reader.date(from: query["endTime"] ?? "")) == moment)
    }

    /// No key, no reading, no traffic: a tile nobody pasted a key into has
    /// nothing to ask for.
    @Test func withoutAKeyNothingIsAsked() async throws {
        let transport = makeTransport()

        let reading = try await makeSource(transport, key: nil).read()

        #expect(reading == nil)
        #expect(transport.requests.isEmpty)
    }

    /// The limits ride BESIDE the reading: a dead quota route empties the
    /// windows and nothing else — the tile keeps its totals, because the
    /// reading source is what decides failing.
    @Test func aDeadQuotaRouteEmptiesTheWindowsAndNothingElse() async throws {
        let transport = makeTransport()
        transport.set(500, body: Data(), for: "limit")

        let reading = try #require(try await makeSource(transport).read())

        #expect(reading.fiveHour == nil)
        #expect(reading.weekly == nil)
        #expect(reading.totalModelCalls == 42)
    }

    /// The reading source dead is the reading dead: the connector reports
    /// failing and nothing else breaks.
    @Test func aDeadModelUsageRouteIsAFailedRead() async {
        let transport = makeTransport()
        transport.set(500, body: Data(), for: "model-usage")

        await #expect(throws: ZaiUsageAPI.Failure.route("/api/monitor/usage/model-usage", 500)) {
            _ = try await makeSource(transport).read()
        }
    }
}

@Suite struct ZaiUsageConnectorTests {
    private struct Reports: ZaiUsageReporting {
        let reading: ZaiUsageReading?
        func read() async throws -> ZaiUsageReading? { reading }
    }

    private func makeConnector(_ reading: ZaiUsageReading?) -> ZaiUsageConnector {
        ZaiUsageConnector(source: Reports(reading: reading))
    }

    private let reading = ZaiUsageReading(
        limits: ZaiUsageDecoder.limits(from: quotaBody),
        totals: ZaiUsageDecoder.totals(from: usageBody),
        observedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    @Test func anEmptyAnswerIsNoReadingAndTheConnectorSaysSo() async {
        await #expect(throws: ZaiUsageConnector.Failure.noReading) {
            _ = try await makeConnector(nil).read()
        }
    }

    /// The AWTRIX face draws all three figures into the app in the loop, in
    /// the order the plan names them: five hours, the week, the MCP month.
    @Test func theAwtrixFaceDrawsTheThreeFiguresInTheLoopsApp() throws {
        let drawn = makeConnector(reading).awtrixFace.draw(reading)

        #expect(drawn.surface == .app("zai"))
        #expect(drawn.scene.text.contains("12%"))
        #expect(drawn.scene.text.contains("35%"))
        #expect(drawn.scene.text.contains("7%"))
        #expect(drawn.scene.color == ZaiUsage.brandColour)
        // Three polls inside one lifetime — the same insurance the Claude
        // figure buys at 300/900.
        #expect(drawn.scene.lifetime == 1_800)
    }

    /// A window the route did not name is a row the face does not carry; the
    /// figure that did arrive still stands.
    @Test func theAwtrixFaceCarriesOnlyTheWindowsThatAnswered() throws {
        let sparse = ZaiUsageReading(
            limits: ZaiUsageLimits(weekly: ZaiUsageWindow(percentUsed: 35)),
            totals: ZaiUsageTotals(), observedAt: nil
        )

        let drawn = makeConnector(sparse).awtrixFace.draw(sparse)

        #expect(drawn.scene.text.contains("35%"))
        #expect(drawn.scene.text.contains("12%") == false)
    }

    /// The TC002 page is the shared three-row usage face, fed the plan's
    /// windows in the order the plan names them: five hours, week, MCP month.
    @Test func theTC002FaceFeedsTheSharedThreeRowFace() {
        let rows = ZaiUsageConnector.rows(for: reading)

        #expect(rows.map(\.label) == ["DAY", "WK", "MCP"])
        #expect(rows.map(\.value) == ["12%", "35%", "7%"])
    }

    /// A window the quota route did not name is a dash, never a zero — the
    /// shared face's own rule, and the band keeps its place on the page.
    @Test func aWindowTheRouteDidNotNameIsADashNeverAZero() {
        let sparse = ZaiUsageReading(
            limits: ZaiUsageLimits(weekly: ZaiUsageWindow(percentUsed: 35)),
            totals: ZaiUsageTotals(), observedAt: nil
        )

        let rows = ZaiUsageConnector.rows(for: sparse)

        #expect(rows.map(\.label) == ["DAY", "WK", "MCP"])
        #expect(rows[0].value == "-")
        #expect(rows[1].value == "35%")
        #expect(rows[2].value == "-")
    }

    /// One frame, one db command — the shared face's whole page — and the
    /// scene it builds always encodes.
    @Test func theTC002FaceShipsTheSharedFaceAsOneBitmap() throws {
        let connector = makeConnector(reading)
        let delivery = try #require(connector.ulanziFace?.draw(reading))

        #expect(delivery.scene.frames.count == 1)
        #expect(delivery.scene.frames[0].draw.count == 1)
        #expect((try UlanziScene(frames: delivery.scene.frames).jsonObject()).isEmpty == false)
    }
}
