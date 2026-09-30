// Sources/PixbarKit/Tiles/Kinds/ClaudeKind.swift
import Foundation

/// Claude usage, read from the status line.
public enum ClaudeKind: TileKind {
    public typealias Parameters = ClaudeTileConfig
    public static let id = ClaudeUsageConnector.id
    public static let presentation = TilePresentation(
        category: .dev, icon: "terminal", blurb: "Claude usage, from the status line"
    )
    public static let models: Set<ClockModel> = [.awtrix3, .ulanziTC002]
}

extension ClaudeTileConfig: TileParameters {}
