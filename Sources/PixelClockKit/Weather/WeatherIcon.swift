/// The weather face's 16x16 animations: the 46 approved icons and `nodata`.
///
/// Raw values are the skill's own names (`weather/icons.py`, `wgen.py`), so a
/// fixture, a Python table and this enum spell every icon the same way. The
/// art lives in `WeatherIconArt.swift`; `WeatherIconTests` holds it to the
/// recorded oracle.
public enum WeatherIcon: String, CaseIterable, Sendable {
    case clearDay, clearNight, mainlyClearDay, mainlyClearNight
    case partlyCloudyDay, partlyCloudyNight, cloudDay, cloudNight
    case fog, rimeFog, drizzle, rain, heavyRain, sleet, freezingRain
    case showersDay, showersNight, snow, snowShowersDay, snowShowersNight
    case frost, thunder, storm, hail
    case windyDay, windyNight, cloudWindy, blizzard, hot, frostyClear
    case moon0, moon1, moon2, moon3, moon4, moon5, moon6, moon7
    case feelsWarm, feelsCold, humidity, wind, umbrella, uv, sunrise, sunset
    case nodata

    /// The animation: 16×16 canvases with their delays in milliseconds.
    ///
    /// The frames are a pure function of the icon, so they are drawn once, on
    /// first use, and served from the table after that.
    public var frames: [(canvas: PixelCanvas, milliseconds: Int)] {
        Self.drawn[self]!
    }

    private static let drawn: [WeatherIcon: [(canvas: PixelCanvas, milliseconds: Int)]] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, weatherIconArt($0)) })
}
