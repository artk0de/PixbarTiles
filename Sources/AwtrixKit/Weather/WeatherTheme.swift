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
    /// Daylight only, and the name says so on purpose. There is no
    /// `partlyCloudyNight` beside it — see the WMO 2 branch below for why the
    /// asymmetry is the decision rather than the omission it looks like.
    case partlyCloudyDay
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
        // 0 clear, 1 mainly clear — a bare sun or a bare moon, so the hour
        // decides which.
        case 0, 1: self = isDay ? .clearDay : .clearNight
        // 2 partly cloudy: broken cloud with the sun behind it, which the
        // catalogue draws and a bare sun overstates for a whole afternoon.
        // By night it goes back to `clearNight`, and that is the
        // decision rather than a missing case: the catalogue has no moon behind
        // a cloud — both weather packs were swept whole to check — so a
        // `partlyCloudyNight` would draw the same moon, over the same `clear`
        // overlay, in the same temperature-derived colour as a clear night. A
        // sky the device cannot draw differently is a branch nobody can see.
        case 2: self = isDay ? .partlyCloudyDay : .clearNight
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
    /// Five skies share `clear`, and that is not a mapping that lost
    /// information: the firmware has no layer for cloud, fog or night, and
    /// drawing rain over an overcast afternoon would be a lie about the
    /// weather. What tells them apart is the theme itself, which is what an
    /// icon is chosen from.
    public var overlay: DeviceOverlay {
        switch self {
        case .clearDay, .clearNight, .partlyCloudyDay, .cloud, .fog: .clear
        case .drizzle: .drizzle
        case .rain: .rain
        case .snow: .snow
        case .frost: .frost
        case .thunder: .thunder
        case .storm: .storm
        }
    }

    /// A night sky: near-black, with only the blue channel lit, and lit at 51 —
    /// the exact floor `TemperatureColour` holds every one of its stops above.
    ///
    /// The value is what the constraint leaves. The panel is 32x8 and a
    /// background lights all 256 pixels of it while a reading is a few dozen
    /// drawn on top, so the digits have a floor to stay above and this has a
    /// ceiling to stay under. Sitting AT that floor is the most this can be
    /// without ever being brighter than the dimmest channel a digit is lit at.
    ///
    /// What it leaves: the dimmest reading the gradient can draw is the cold
    /// clamp, #3333FF, and it puts out about 18 times the light of this. That
    /// is also the closest reading to this in hue — both are blue — so it is
    /// the one most at risk of disappearing into the panel, and it is the case
    /// the swept test in `TemperatureColourTests` pins. On the blue channel the
    /// two share it is 255 against 51, five to one, and the reading carries red
    /// and green at 51 against a panel that is unlit in both.
    ///
    /// Rejected: a mid navy — #000080, #191970 — which would be plainly visible
    /// and is the obvious choice on a bright screen. The clock runs at
    /// brightness 2 to 3, where the firmware's `nscale8` collapses every
    /// channel to nearly nothing, so a background chosen to survive that
    /// collapse lands on the same LED level as the digits do. The cold end of
    /// the gradient is blue, and it would vanish into a blue wall. Losing the
    /// tint in a dark room is the cheaper mistake than losing the reading.
    public static let nightSky = "#000033"

    /// The colour of the panel behind the reading, or nil to leave it unlit.
    ///
    /// Takes the hour rather than reading it off `self`, and that is the
    /// decision rather than an oversight. The hour is not a property of the
    /// SKY: only `clearDay` and `clearNight` split on it, and they split
    /// because the ICON had to — a sun and a moon are different pictures.
    /// Doubling all eleven cases to carry one boolean would produce twenty,
    /// nineteen of which draw their partner's picture over their partner's
    /// overlay, and `partlyCloudyDay` already has the argument written against
    /// it: a sky the device cannot draw differently is a branch nobody sees.
    /// The hour is an axis beside the sky, so it is passed beside it.
    ///
    /// Static for the same reason — with the sky unable to answer, an instance
    /// member would invite `WeatherTheme.clearNight.background(isDay: true)`,
    /// which has no honest answer at all.
    ///
    /// Day is nil rather than a light colour. An unlit panel is what the device
    /// does by default and what every other app in the loop looks like, so a
    /// daytime tint would make the weather the odd one out in the rotation for
    /// saying what its own absence already says.
    public static func background(isDay: Bool) -> String? {
        isDay ? nil : nightSky
    }

    /// The picture drawn beside the reading, from the LaMetric catalogue.
    ///
    /// A switch rather than a dictionary, so that a sky added to this enum
    /// fails to compile until somebody chooses its picture. A dictionary would
    /// compile with the entry missing and answer nil at the poll — an app drawn
    /// beside whatever the previous one in the loop left on the matrix, which
    /// nothing on the device or in this app would report.
    ///
    /// Every id below was fetched and its frames counted: all eleven are 8x8
    /// animated GIFs, which is the only thing the clock draws. The catalogue
    /// has no public search, so an id costs a download and a look — do not
    /// invent one, and do not go hunting for a better one.
    ///
    /// `drizzle`, `frost` and `storm` deliberately borrow a neighbour's
    /// picture, because the catalogue has nothing of their own yet. It is a
    /// placeholder rather than an oversight, and it is not a mapping that lost
    /// anything: each of the three drives a different firmware overlay, so the
    /// device still tells them apart on the layer that draws over everything.
    /// Art of their own replaces one line here and one line in the test's
    /// table.
    public var icon: IconReference {
        switch self {
        case .clearDay: .catalogue(2282)          // sun, 7 frames
        case .clearNight: .catalogue(12181)       // crescent moon with stars, 4 frames
        case .partlyCloudyDay: .catalogue(53802)  // a cloud with the sun behind it, 16 frames
        case .cloud: .catalogue(53384)            // a cloud drifting across, 16 frames
        case .fog: .catalogue(17056)              // horizontal grey bars, 2 frames
        case .drizzle: .catalogue(2284)           // shared with rain, awaiting its own art
        case .rain: .catalogue(2284)              // cloud with blue drops, 5 frames
        case .snow: .catalogue(2289)              // cloud with white flakes, 9 frames
        case .frost: .catalogue(2289)             // shared with snow, awaiting its own art
        case .thunder: .catalogue(49299)          // rain with a bolt on frames 2 and 4, 7 frames
        case .storm: .catalogue(49299)            // shared with thunder, awaiting its own art
        }
    }
}
