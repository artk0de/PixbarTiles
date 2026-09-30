import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The night light comes up with its window and hands the panel back.
@MainActor
@Suite struct NightLightWiringTests {
    private let clockId = UUID()
    private var key: TileKey { TileKey(clockId: clockId, connectorId: NightLightKind.id) }
    private var weather: TileKey { TileKey(clockId: clockId, connectorId: WeatherKind.id) }
    private var github: TileKey { TileKey(clockId: clockId, connectorId: GitHubKind.id, instance: "a/b") }

    private final class Log {
        var steps: [String] = []
    }

    private func actions(_ log: Log) -> TileArrivalActions {
        TileArrivalActions(
            run: { log.steps.append("run \($0.connectorId)") },
            show: { log.steps.append("show \($0.connectorId)") },
            idle: { log.steps.append("idle \($0.connectorId)") },
            morningTile: { [weather, github] _, preferred, _ in
                preferred == github.tileId ? github : weather
            }
        )
    }

    @Test func itsWindowOpeningRunsItThenShowsIt() {
        let log = Log()
        NightLightWiring().arrived(key, nil, actions(log))
        #expect(log.steps == ["run nightlight", "show nightlight"])
    }

    @Test func itsWindowClosingIdlesItThenShowsTheMorningTile() {
        let log = Log()
        NightLightWiring().left(key, NightLightTileConfig(), actions(log))
        #expect(log.steps == ["idle nightlight", "show weather"])
    }

    @Test func aChosenMorningTileIsTheOneShown() {
        let log = Log()
        NightLightWiring().left(key, NightLightTileConfig(morningTileId: github.tileId), actions(log))
        #expect(log.steps == ["idle nightlight", "show github"])
    }

    @Test func withoutAutoShowTheClockIsLeftAlone() {
        let log = Log()
        let manual = NightLightTileConfig(autoShow: false)
        NightLightWiring().arrived(key, manual, actions(log))
        NightLightWiring().left(key, manual, actions(log))
        #expect(log.steps.isEmpty)
    }

    @Test func theNamingInstanceStartsFromTheNightTheMacCanName() {
        let sleep = ConnectorFactories.namingInstances(transport: StubTransport(), canNameSleep: { true })
            .first { $0.id == NightLightKind.id }
        let hours = ConnectorFactories.namingInstances(transport: StubTransport())
            .first { $0.id == NightLightKind.id }
        #expect(sleep?.defaultPolicy == TileDefaults.nightLightSleep)
        #expect(hours?.defaultPolicy == TileDefaults.nightLightHours)
    }
}
