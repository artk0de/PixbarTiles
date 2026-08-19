import Foundation

/// The clock's device-wide weather layer, as the firmware names it.
///
/// Six names, enumerated by setting each one on the real device and reading it
/// back. There is no seventh: an unrecognised value is accepted, answered 200
/// and then silently coerced to `clear`, so a typo produces a clock that simply
/// never draws rain with nothing on either side to say why. That is what makes
/// this a closed type rather than a `String` — the enum IS the validation,
/// because the device performs none.
///
/// The layer draws over everything on screen and belongs to the device rather
/// than to an app, which is the whole difficulty of using it: see
/// `DeviceCustody` for what has to be remembered before it is written.
public enum DeviceOverlay: String, Sendable, Equatable, CaseIterable {
    case clear
    case drizzle
    case rain
    case snow
    case storm
    case thunder
    case frost

    /// What the firmware accepts, written down from the hardware enumeration.
    ///
    /// Deliberately a second statement of the cases above rather than something
    /// derived from them. Derived, it would agree with any typo introduced into
    /// a case's raw value, and a typo is the one failure the device cannot
    /// report — which leaves this the only place it can be caught.
    public static let namesTheFirmwareAccepts: Set<String> = [
        "clear", "drizzle", "rain", "snow", "storm", "thunder", "frost",
    ]

    /// The six weather layers — every accepted value except `clear`, which is
    /// the absence of weather rather than a kind of it. Seven names reach the
    /// device; six of them draw something.
    public static let weather: [DeviceOverlay] = allCases.filter { $0 != .clear }
}

/// One sky, as the clock shows it.
///
/// A closed set rather than a struct built per reading, because the clock has
/// exactly this many looks and two of them differ only by the hour: a clear
/// night rendered as a bright sun is the kind of wrongness that gets noticed
/// immediately, and it cannot be expressed by the overlay at all — there is no
/// night overlay. The distinction is kept here for the icon to draw. The app's
/// colour used to carry it and cannot any more: the colour answers how the
/// temperature feels, which is a different question from what the sky is doing.
public enum WeatherTheme: String, Sendable, Equatable, CaseIterable {
    case clearDay
    case clearNight
    case cloud
    case fog
    case drizzle
    case rain
    case snow
    case frost
    case thunder
    case storm

    /// The sky a WMO code describes, split by whether the sun is up.
    ///
    /// Anything outside the documented codes lands on a clear day rather than
    /// on a name the device would reject. The firmware's coercion means an
    /// invalid overlay and a clear sky look identical on the clock, so the
    /// fallback may as well be the one this app can also reason about.
    public init(code: Int, isDay: Bool) {
        switch code {
        // 0 clear, 1 mainly clear, 2 partly cloudy — the sun or the moon is
        // still the thing being drawn, so the hour decides which.
        case 0, 1, 2: self = isDay ? .clearDay : .clearNight
        // 3 overcast. Nothing behind it to have set.
        case 3: self = .cloud
        case 45: self = .fog
        // 48 depositing rime fog: ice on every surface, which is frost rather
        // than fog however it arrived.
        case 48: self = .frost
        // 51/53/55 drizzle. Its own band in WMO and its own layer on the
        // device, verified against the clock — drawing it as rain spends a
        // layer the firmware offers and overstates what is falling.
        case 51, 53, 55: self = .drizzle
        // 61/63/65 rain, 80/81/82 rain showers.
        case 61, 63, 65, 80, 81, 82: self = .rain
        // 56/57 freezing drizzle, 66/67 freezing rain. NOT the drizzle band,
        // deliberately: what matters about freezing drizzle is the ice it
        // leaves, which is the same news 66/67 and rime fog carry, and it is
        // the half a person acts on before leaving the house.
        case 56, 57, 66, 67: self = .frost
        // 71/73/75 snow fall, 77 snow grains, 85/86 snow showers.
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95: self = .thunder
        // 96/99 thunderstorm with hail — the violent one, and the device has a
        // separate layer for it.
        case 96, 99: self = .storm
        default: self = isDay ? .clearDay : .clearNight
        }
    }

    /// The device-wide layer this sky draws.
    ///
    /// Four skies share `clear`, and that is not a mapping that lost
    /// information: the firmware has no layer for cloud, fog or night, and
    /// drawing rain over an overcast afternoon would be a lie about the
    /// weather. What tells them apart is the theme itself, which is what an
    /// icon is chosen from.
    public var overlay: DeviceOverlay {
        switch self {
        case .clearDay, .clearNight, .cloud, .fog: .clear
        case .drizzle: .drizzle
        case .rain: .rain
        case .snow: .snow
        case .frost: .frost
        case .thunder: .thunder
        case .storm: .storm
        }
    }
}
