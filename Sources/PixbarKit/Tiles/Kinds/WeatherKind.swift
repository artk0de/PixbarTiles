// Sources/PixbarKit/Tiles/Kinds/WeatherKind.swift
import Foundation

/// The sky where the clock is, on either clock.
public enum WeatherKind: TileKind {
    public typealias Parameters = WeatherTileConfig
    public static let id = WeatherConnector.appName
    public static let presentation = TilePresentation(
        category: .weather, icon: "cloud.sun", blurb: "The sky where the clock is"
    )
    public static let models: Set<ClockModel> = [.awtrix3, .ulanziTC002]
}

extension WeatherTileConfig: TileParameters {}
