import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// The defaults table reaches a tile through its connector. Each shipped
// connector answers its own row, and a row's refresh is the connector's own
// cadence, so a new tile runs as often as the connector always has.

private struct NoReading: ClaudeUsageReporting {
    func read() async throws -> ClaudeUsageReading? { nil }
}

private struct NoZaiReading: ZaiUsageReporting {
    func read() async throws -> ZaiUsageReading? { nil }
}

@MainActor private func shipped() -> [(connector: any Connector, row: TilePolicy)] {
    [
        (weatherConnector(over: StubTransport(body: Data())), TileDefaults.weather),
        (ClaudeUsageConnector(reporter: NoReading()), TileDefaults.codeUsage),
        (
            AppModel.anecdoteWiring(
                transport: StubTransport(body: Data()),
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("defaults-\(UUID().uuidString).json")
            ).connector,
            TileDefaults.anecdotes
        ),
        (
            ZaiUsageConnector(
                source: ZaiUsageAPI(transport: StubTransport(body: Data()), key: { nil })
            ),
            TileDefaults.codeUsage
        ),
    ]
}

@Test @MainActor func eachShippedConnectorStartsItsTileFromItsOwnRow() {
    for (connector, row) in shipped() {
        #expect(connector.defaultPolicy == row, "\(connector.id)")
    }
}

@Test @MainActor func aNewTileRunsAtItsConnectorsOwnCadence() {
    for (connector, _) in shipped() {
        #expect(connector.defaultPolicy.refresh == connector.defaultInterval, "\(connector.id)")
    }
}

// A connector that names nothing keeps what the app-wide rules did to it:
// held where they held an audible one, and nowhere if it cannot be heard.
@Test func anAudibleConnectorThatNamesNoPolicyKeepsTheOldQuietHoursRow() {
    let policy = StubConnector().defaultPolicy

    #expect(policy.refresh == StubConnector().defaultInterval)
    #expect(policy.focus == FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold))
    #expect(policy.window == .quiet(HourWindow(startHour: 23, endHour: 8)))
}

@Test func aSilentConnectorThatNamesNoPolicyIsHeldByNothing() {
    #expect(silentConnector.defaultPolicy == TilePolicy(refreshSeconds: 900))
}


// MARK: - The Coding Subscription's own ladder

// One minute is the cadence a subscription's usage is watched at, and the two
// tiles that report one say so themselves rather than being named in a table
// somewhere else.
@Test @MainActor func theCodingSubscriptionConnectorsRefreshEveryMinuteByDefault() {
    for (connector, _) in shipped() where connector.refreshSteps == RefreshScale.codingSubscription {
        #expect(connector.defaultInterval == 60, "\(connector.id)")
    }
    #expect(TileDefaults.codeUsage.refreshSeconds == 60)
    #expect(TileDefaults.codeUsage.refreshSeconds == 60)
}

// Which connector is offered which ladder, said once and in full. A ladder
// reaching a connector it was not meant for is the failure that cannot be seen
// on screen: the picker looks right and the cadence behind it is somebody
// else's.
@Test @MainActor func eachConnectorIsOfferedTheLadderItNames() {
    let expected: [String: [TimeInterval]] = [
        ClaudeUsageConnector.id: RefreshScale.codingSubscription,
        ZaiUsageConnector.connectorId: RefreshScale.codingSubscription,
        WeatherConnector.appName: RefreshScale.weatherFetch,
    ]
    for (connector, _) in shipped() {
        #expect(
            connector.refreshSteps == expected[connector.id] ?? RefreshScale.steps,
            "\(connector.id)"
        )
    }
    // Ten seconds is the Coding Subscription's alone: it is the step that asks
    // a free forecast API for 360 answers an hour.
    for (connector, _) in shipped() where connector.id != ClaudeUsageConnector.id
        && connector.id != ZaiUsageConnector.connectorId
    {
        #expect(connector.refreshSteps.contains(10) == false, "\(connector.id)")
    }
}
