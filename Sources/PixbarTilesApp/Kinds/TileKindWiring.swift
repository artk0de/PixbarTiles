import Foundation
import PixbarKit

/// What every wiring may build a clock's connectors from: the app's shared
/// sources, handed in once by the composition root.
struct TileEnvironment {
    let transport: any Transport
    let defaults: UserDefaults
    let secrets: any SecretStoring
    /// One weather source for every clock — it caches per place.
    let weather: OpenMeteoSource
    /// The one anecdote connector: one queue for the whole app.
    let anecdotes: any Connector
    /// Where a clock's Claude tile reads its usage — one per clock, since the
    /// status-line reporter keeps the last window it saw.
    let claudeReporter: @Sendable () -> any ClaudeUsageReporting
}

/// One kind of tile, as the app wires it: the connectors it builds for a
/// clock, the instance the app-wide registry names it by, the glyph it wears
/// and what its settings block carries. The kit's `TileKind` says what the
/// tile IS; this says how the app makes and shows it.
protocol TileKindWiring: Sendable {
    associatedtype Kind: TileKind
    /// Registers what this kind runs through on one clock. Called once per
    /// clock, so what must remember across runs is built here, outside the
    /// factory the registry calls on every run.
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment)
    /// The instance the app-wide registry holds only so the store can name
    /// it, or nil when the composition root registers one of its own.
    func namingInstance(transport: any Transport) -> (any Connector)?
    var tileGlyph: [String] { get }
    /// Whether the kind's own settings block carries the refresh control.
    var namesItsOwnRefresh: Bool { get }
}

extension TileKindWiring {
    var kindId: String { Kind.id }
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {}
    func namingInstance(transport: any Transport) -> (any Connector)? { nil }
    var namesItsOwnRefresh: Bool { false }
}

/// Every wiring in the app, one per kind in `TileKinds.all`, listed once.
enum AppTileKinds {
    static let all: [any TileKindWiring] = [
        WeatherWiring(), ClaudeWiring(), ZaiWiring(), GitHubWiring(), AnecdotesWiring(), VPNWiring(),
    ]

    static func wiring(for connectorId: String) -> (any TileKindWiring)? {
        all.first { $0.kindId == connectorId }
    }
}
