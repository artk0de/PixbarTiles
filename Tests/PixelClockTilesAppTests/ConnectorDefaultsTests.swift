import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The defaults table reaches a tile through its connector. Each shipped
// connector answers its own row, and a row's refresh is the connector's own
// cadence, so a new tile runs as often as the connector always has.

private struct NoReading: ClaudeUsageReporting {
    func read() async throws -> ClaudeUsageReading? { nil }
}

@MainActor private func shipped() -> [(connector: any Connector, row: TilePolicy)] {
    [
        (weatherConnector(over: StubTransport(body: Data())), TileDefaults.weather),
        (ClaudeUsageConnector(reporter: NoReading()), TileDefaults.claude),
        (
            AppModel.anecdoteWiring(
                transport: StubTransport(body: Data()),
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("defaults-\(UUID().uuidString).json")
            ).connector,
            TileDefaults.anecdotes
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
