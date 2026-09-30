// Sources/PixbarKit/Tiles/Kinds/NightLightKind.swift
import Foundation

/// A warm scene for the night, filling a TC002's panel. TC002 only: the
/// AWTRIX encoder carries text and an icon, not a full-screen animation.
public enum NightLightKind: TileKind {
    public typealias Parameters = NightLightTileConfig
    public static let id = "nightlight"
    public static let presentation = TilePresentation(
        category: .system, icon: "moon.stars", blurb: "A warm scene for the night"
    )
    public static let models: Set<ClockModel> = [.ulanziTC002]
}
