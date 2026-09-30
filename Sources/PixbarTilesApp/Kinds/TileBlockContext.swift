import PixbarKit
import SwiftUI

/// What a kind's settings block is handed by the tile settings window: the
/// tile, its parameters opened to the kind's type, and the window's own
/// means — the save facade, the refresh control, the history sheet.
@MainActor
struct TileBlockContext<Parameters> {
    let key: TileKey
    /// The tile's stored parameters, or nil for a tile with none yet.
    let parameters: Parameters?
    let settings: TileSettingsModel
    let model: AppModel
    /// The shared refresh control, under the label the block chooses.
    let refresh: (_ label: String) -> TileRefreshControl
    /// Opens the anecdote history sheet.
    let openHistory: () -> Void
    /// Claude Code's machine-wide link, built when a block asks for it.
    let claudeCode: () -> ClaudeCodeLinkModel

    /// The same context with its parameters as one kind's type.
    func opened<P>(as type: P.Type) -> TileBlockContext<P> {
        TileBlockContext<P>(
            key: key, parameters: parameters as? P, settings: settings, model: model,
            refresh: refresh, openHistory: openHistory, claudeCode: claudeCode
        )
    }
}

extension TileKindWiring {
    /// This kind's block, for a window that holds the wiring as `any`.
    @MainActor
    func settingsBlock(_ context: TileBlockContext<any TileParameters>) -> AnyView {
        AnyView(block(context.opened(as: Kind.Parameters.self)))
    }
}

extension TileKindWiring where Block == EmptyView {
    @MainActor
    func block(_ context: TileBlockContext<Kind.Parameters>) -> EmptyView { EmptyView() }
}

/// The shared usage face's two pickers — the same block on the Claude tile
/// and the z.ai tile, because the face they tune is one.
struct CodeUsageParametersBlock: View {
    let settings: TileSettingsModel

    var body: some View {
        if let usageFace = settings.parameters {
            CodeUsageBlock(config: usageFace, onChange: { settings.setParameters($0) })
        }
    }
}
