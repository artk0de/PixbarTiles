// Sources/PixbarKit/Tiles/Kinds/ZaiKind.swift
import Foundation

/// z.ai usage, week to date.
public enum ZaiKind: TileKind {
    public typealias Parameters = ZaiTileConfig
    public static let id = ZaiUsageConnector.connectorId
    public static let presentation = TilePresentation(
        category: .dev, icon: "chart.bar", blurb: "z.ai usage, week to date"
    )
    public static let models: Set<ClockModel> = [.awtrix3, .ulanziTC002]
}

extension ZaiTileConfig: TileParameters {}
