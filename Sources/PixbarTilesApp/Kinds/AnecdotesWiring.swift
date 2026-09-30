import Foundation
import PixbarKit
import SwiftUI

struct AnecdotesWiring: TileKindWiring {
    typealias Kind = AnecdotesKind
    var tileGlyph: [String] { PanelGlyph.anecdoteTile }

    /// The one shared connector on every clock: one queue for the whole app
    /// (see `AppModel.anecdoteWiring`).
    @MainActor func register(into registry: ConnectorRegistry, for clock: ClockRecord, _ env: TileEnvironment) {
        registry.register(env.anecdotes)
    }

    func block(_ context: TileBlockContext<NoParameters>) -> some View {
        AnecdoteTileBlock(onHistory: context.openHistory)
    }
}
