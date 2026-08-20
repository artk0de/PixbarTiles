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
    case partlyCloudyDay
    case partlyCloudyNight
    case cloudDay
    case cloudNight
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
        // 2 partly cloudy: broken cloud with something behind it, which a bare
        // sun or a bare moon overstates for a whole afternoon or a whole night.
        //
        // The night half used to collapse into `clearNight`, and that was a
        // decision with a reason: the catalogue has no moon behind a cloud —
        // both weather packs were swept whole to check — so the branch would
        // have drawn the same moon over the same `clear` overlay, and nobody
        // could have seen it. The reason expired. Art for it arrived from
        // outside the catalogue and ships with this app, so the branch draws
        // something of its own and earns its place.
        case 2: self = isDay ? .partlyCloudyDay : .partlyCloudyNight
        // 3 overcast — nothing behind it to have set, but still a sky that
        // looks different at midnight than at noon, and the two were one
        // picture until there was a second one to draw.
        case 3: self = isDay ? .cloudDay : .cloudNight
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
    /// Seven skies share `clear`, and that is not a mapping that lost
    /// information: the firmware has no layer for cloud, fog or night, and
    /// drawing rain over an overcast afternoon would be a lie about the
    /// weather. Probed against the clock on 2026-08-20 rather than assumed —
    /// `fog`, `cloud`, `cloudy`, `night`, `wind`, `hail` and `sun` are every one
    /// of them coerced to `clear`, while `frost` and `thunder` written in the
    /// same pass came back verbatim. What tells the seven apart is the theme
    /// itself, which is what an icon is chosen from.
    public var overlay: DeviceOverlay {
        switch self {
        case .clearDay, .clearNight, .partlyCloudyDay, .partlyCloudyNight,
             .cloudDay, .cloudNight, .fog: .clear
        case .drizzle: .drizzle
        case .rain: .rain
        case .snow: .snow
        case .frost: .frost
        case .thunder: .thunder
        case .storm: .storm
        }
    }

    /// The picture drawn beside the reading, from the LaMetric catalogue.
    ///
    /// A switch rather than a dictionary, so that a sky added to this enum
    /// fails to compile until somebody chooses its picture. A dictionary would
    /// compile with the entry missing and answer nil at the poll — an app drawn
    /// beside whatever the previous one in the loop left on the matrix, which
    /// nothing on the device or in this app would report.
    ///
    /// Every picture below was fetched and its frames counted: all thirteen are
    /// 8x8 animated GIFs, which is the only thing the clock draws. The
    /// catalogue has no public search — the firmware's own icon page previews
    /// by id and nothing more, checked on 2026-08-20 — so an id costs a
    /// download and a look. Do not invent one, and do not go hunting for a
    /// better one.
    ///
    /// Two skies name `.bundled` art instead, and that is what a sky with no
    /// catalogue picture looks like once somebody finds one elsewhere: the
    /// bytes ship in this package and install by the same route, so the promise
    /// on a clock that has never run this app is the one `.catalogue` makes.
    /// `.installed` would not make it, which is why no sky here uses it.
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
        // A crescent behind a drifting cloud, 24 frames. The crescent is the
        // reason this one was picked over the round-moon cut of the same
        // animation: `clearNight` already draws a crescent, so the moon stays
        // the constant and the cloud is what changes — which is the only thing
        // this sky is telling you that a clear night is not.
        case .partlyCloudyNight: .bundled("PartlyCloudyNightHalfMoon")
        case .cloudDay: .catalogue(53384)         // a cloud drifting across, 16 frames
        // A grey mass filling most of the tile with a white cloud under it, 32
        // frames. Darkest of the three and the only one with no moon to speak
        // of, which is what makes it read as overcast rather than broken cloud.
        case .cloudNight: .bundled("ani_partly_cloudy_night")
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
