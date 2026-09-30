import Foundation
import PixbarKit
import SwiftUI

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
    associatedtype Block: View = EmptyView
    /// The kind's own block in the tile settings window, beside the shared
    /// policy editor: what this kind has that no other does.
    @MainActor @ViewBuilder func block(_ context: TileBlockContext<Kind.Parameters>) -> Block
    /// The tile's policy has just started letting it run — its hours began,
    /// or a Focus that held it ended. Heard after the schedule's own answer.
    @MainActor func arrived(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions)
    /// The tile's policy has just stopped letting it run.
    @MainActor func left(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions)
}

extension TileKindWiring {
    var kindId: String { Kind.id }
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {}
    func namingInstance(transport: any Transport) -> (any Connector)? { nil }
    var namesItsOwnRefresh: Bool { false }
    @MainActor func arrived(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions) {}
    @MainActor func left(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions) {}

    /// Tells `arrived` or `left`, with the tile's stored parameters, opened to this
    /// kind's type — for a caller that holds the wiring as `any`.
    @MainActor
    func notify(_ record: TileRecord, arrived: Bool, _ actions: TileArrivalActions) {
        let parameters = record.config?.value(as: Kind.Parameters.self)
        if arrived {
            self.arrived(record.key, parameters, actions)
        } else {
            left(record.key, parameters, actions)
        }
    }
}

/// What a wiring may do when its tile's window opens or closes.
@MainActor
struct TileArrivalActions {
    /// Runs the tile now (`TileRunner.runNow`).
    let run: (TileKey) -> Void
    /// Switches the tile's clock to the tile's page.
    let show: (TileKey) -> Void
    /// Tells a TC002 the tile has nothing to show, so its page leaves the
    /// rotation.
    let idle: (TileKey) -> Void
    /// The first tile on that clock, in stored order, that owns a page and
    /// is not the one excluded — where the clock is sent back to.
    let morningTile: (_ clockId: UUID, _ excluding: TileKey) -> TileKey?
}

/// Every wiring in the app, one per kind in `TileKinds.all`, listed once.
enum AppTileKinds {
    static let all: [any TileKindWiring] = [
        WeatherWiring(), ClaudeWiring(), ZaiWiring(), GitHubWiring(), AnecdotesWiring(), VPNWiring(),
        NightLightWiring(),
    ]

    static func wiring(for connectorId: String) -> (any TileKindWiring)? {
        all.first { $0.kindId == connectorId }
    }
}
