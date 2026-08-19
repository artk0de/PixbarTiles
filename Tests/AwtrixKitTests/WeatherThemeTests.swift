import Foundation
import Testing
@testable import AwtrixKit

// The mapping from a WMO code to what the clock shows.
//
// The firmware coerces an overlay name it does not know to `clear` — silently,
// with no error anywhere — so a typo produces a clock that simply never draws
// rain, and nothing on either side says why. That makes this file the only
// validation there is, and it is why the six accepted names are written down
// separately from the enum that carries them: a test comparing the enum against
// itself would pass through any typo at all.

/// One documented WMO group and the overlay it has to reach.
private struct Group {
    let codes: [Int]
    let overlay: DeviceOverlay
    let what: String
}

private let groups: [Group] = [
    Group(codes: [0], overlay: .clear, what: "clear sky"),
    Group(codes: [1, 2], overlay: .clear, what: "mainly clear and partly cloudy"),
    Group(codes: [3], overlay: .clear, what: "overcast"),
    Group(codes: [45], overlay: .clear, what: "fog"),
    Group(codes: [48], overlay: .frost, what: "depositing rime fog"),
    Group(codes: [51, 53, 55], overlay: .drizzle, what: "drizzle"),
    Group(codes: [56, 57], overlay: .frost, what: "freezing drizzle"),
    Group(codes: [61, 63, 65], overlay: .rain, what: "rain"),
    Group(codes: [66, 67], overlay: .frost, what: "freezing rain"),
    Group(codes: [71, 73, 75, 77], overlay: .snow, what: "snow fall and snow grains"),
    Group(codes: [80, 81, 82], overlay: .rain, what: "rain showers"),
    Group(codes: [85, 86], overlay: .snow, what: "snow showers"),
    Group(codes: [95], overlay: .thunder, what: "thunderstorm"),
    Group(codes: [96, 99], overlay: .storm, what: "thunderstorm with hail"),
]

@Test func eachWmoGroupMapsToOneOfTheSixOverlaysTheFirmwareAccepts() {
    var reached: Set<DeviceOverlay> = []

    for group in groups {
        for code in group.codes {
            let theme = WeatherTheme(code: code, isDay: true)
            #expect(
                theme.overlay == group.overlay,
                "WMO \(code) (\(group.what)) drew \(theme.overlay.rawValue)"
            )
            #expect(DeviceOverlay.namesTheFirmwareAccepts.contains(theme.overlay.rawValue))
            reached.insert(theme.overlay)
        }
    }

    // The trap this test exists in front of: a mapping that answers `clear` for
    // every code satisfies every expectation above, because `clear` is one of
    // the seven and the groups would all agree with each other. Every one of
    // them has to be reached by real codes — `storm` and `thunder` are separate
    // skies, `frost` is not `snow`, `drizzle` is not `rain`, and none of them is
    // the absence of weather.
    #expect(reached == Set(DeviceOverlay.allCases))
    #expect(reached.count == 7)
}

// The one rule that cannot be read off the device: an overlay name outside the
// six is taken, answered 200, and then quietly ignored. So the type carrying
// them is the validation, and this is the check that it is telling the truth.
@Test func everyOverlayTheAppCanSendIsOneTheFirmwareAccepts() {
    #expect(Set(DeviceOverlay.allCases.map(\.rawValue))
        == DeviceOverlay.namesTheFirmwareAccepts)
    // Seven names reach the device; six of them draw weather, and `clear` is
    // what the other six are the absence of.
    #expect(DeviceOverlay.namesTheFirmwareAccepts.count == 7)
    #expect(DeviceOverlay.weather.count == 6)
    #expect(DeviceOverlay.weather.contains(.clear) == false)
}

@Test func anUnknownWmoCodeFallsBackToClearRatherThanToAnInvalidOverlay() {
    // 4 and 100 are not WMO codes at all; -1 is what an unsigned field would
    // never hold and a malformed response might.
    for code in [-1, 4, 7, 100, 999] {
        let theme = WeatherTheme(code: code, isDay: true)

        #expect(theme.overlay == .clear)
        #expect(DeviceOverlay.namesTheFirmwareAccepts.contains(theme.overlay.rawValue))
    }
}

@Test func clearSkyByDayAndByNightAreDifferentThemes() {
    let day = WeatherTheme(code: 0, isDay: true)
    let night = WeatherTheme(code: 0, isDay: false)

    #expect(day != night)
    // Different themes, same overlay: `is_day` decides which sky this is, and
    // there is no night overlay for it to reach for. Without this, a mapping
    // that answered a made-up overlay for the night would pass the inequality
    // above and put no weather on the device at all.
    #expect(day.overlay == .clear)
    #expect(night.overlay == .clear)
}

// And the split reaches the codes either side of a clear sky, where the sun is
// still the thing being drawn.
@Test func aPartlyCloudySkyIsAlsoDrawnDifferentlyByNight() {
    #expect(WeatherTheme(code: 2, isDay: true) != WeatherTheme(code: 2, isDay: false))
    // Overcast is not: there is no sun behind it to have set.
    #expect(WeatherTheme(code: 3, isDay: true) == WeatherTheme(code: 3, isDay: false))
}

// Code 2 is broken cloud, and the catalogue draws exactly that: a cloud with
// the sun behind it. Collapsing it into the clear day put a bare sun over an
// afternoon of cloud — the kind of wrongness a display meant to be glanced at
// states loudest.
@Test func aPartlyCloudyDayIsItsOwnSkyRatherThanAClearOne() {
    let partlyCloudy = WeatherTheme(code: 2, isDay: true)

    #expect(partlyCloudy != WeatherTheme(code: 0, isDay: true))
    #expect(partlyCloudy != WeatherTheme(code: 1, isDay: true))
    #expect(
        partlyCloudy.icon == .catalogue(53802),
        "WMO 2 by day drew \(partlyCloudy.icon)"
    )
    // Same overlay as before, and no information is lost by that: the firmware
    // has no layer for cloud, so the eight pixels beside the number are the
    // only place the difference can appear at all.
    #expect(partlyCloudy.overlay == .clear)
}

// And there is deliberately no night half to it. The catalogue has no moon
// behind a cloud — both weather packs were swept whole to check — so a
// `partlyCloudyNight` would draw the same moon as `clearNight`, over the same
// `clear` overlay, in the same temperature-derived colour. This test is what
// records that the asymmetry was chosen: a sky the device cannot draw
// differently is a branch nobody can ever see, and the next reader should not
// "fix" it.
@Test func aPartlyCloudyNightStaysAClearNightBecauseNothingCouldDrawItApart() {
    #expect(WeatherTheme(code: 2, isDay: false) == .clearNight)

    // The codes either side of it are untouched in both lighting conditions: 0
    // and 1 are a bare sun or a bare moon, which is what they look like.
    #expect(WeatherTheme(code: 0, isDay: true) == .clearDay)
    #expect(WeatherTheme(code: 1, isDay: true) == .clearDay)
    #expect(WeatherTheme(code: 0, isDay: false) == .clearNight)
    #expect(WeatherTheme(code: 1, isDay: false) == .clearNight)
}

// WMO separates 51–55 from 61–65 because drizzle is not rain, and the firmware
// separates them too — `drizzle` is one of the seven values it accepts,
// enumerated by setting each on the real clock and reading it back:
//
//     set drizzle -> device reports: drizzle
//     set hail    -> device reports: clear
//
// Mapping the band to `rain` spent a layer the device offers and overstated
// light precipitation on a display whose whole job is to be glanced at.
@Test func theDrizzleBandSelectsTheDrizzleOverlayRatherThanRain() {
    for code in [51, 53, 55] {
        let theme = WeatherTheme(code: code, isDay: true)

        #expect(theme.overlay == .drizzle, "WMO \(code) drew \(theme.overlay.rawValue)")
        #expect(theme.overlay != .rain)
    }

    // The band either side of it is untouched: rain is still rain, and the
    // freezing codes still say ice rather than wet.
    #expect(WeatherTheme(code: 61, isDay: true).overlay == .rain)
    #expect(WeatherTheme(code: 56, isDay: true).overlay == .frost)
    #expect(DeviceOverlay.namesTheFirmwareAccepts.contains("drizzle"))
}

// MARK: - The picture beside the number

/// The catalogue id each sky draws, written down here separately from the type
/// that carries them — the same reason the overlay names are written twice. A
/// table compared against itself agrees with any typo introduced into it.
///
/// This is also the record of what was verified: the catalogue has no public
/// search, so every id below cost a download and a look at its frames, and all
/// eleven are 8x8 animated GIFs, which is the only thing the device draws.
private let verifiedIcons: [WeatherTheme: Int] = [
    .clearDay: 2282,
    .clearNight: 12181,
    .partlyCloudyDay: 53802,
    .cloud: 53384,
    .fog: 17056,
    .drizzle: 2284,
    .rain: 2284,
    .snow: 2289,
    .frost: 2289,
    .thunder: 49299,
    .storm: 49299,
]

/// The id inside a catalogue reference, or nil for one already on the flash.
private func catalogueId(_ reference: IconReference) -> Int? {
    guard case let .catalogue(id) = reference else { return nil }
    return id
}

@Test func everySkyDrawsTheCatalogueIconThatWasVerifiedForIt() throws {
    // A sky added without an id would otherwise reach the device drawing
    // whatever its neighbour draws, which is the one failure this file exists
    // to catch: the clock shows a picture either way.
    #expect(verifiedIcons.count == WeatherTheme.allCases.count)

    for theme in WeatherTheme.allCases {
        let id = try #require(verifiedIcons[theme], "no verified icon for \(theme.rawValue)")

        #expect(theme.icon == .catalogue(id), "\(theme.rawValue) drew \(theme.icon)")
    }
}

// Every sky reaches for the catalogue rather than for a name assumed to be on
// the flash. `.installed` would be a promise about a device this app has never
// listed — on a clock that has never run it, the app draws no picture at all
// and nothing anywhere says why.
@Test func noSkyAssumesItsPictureIsAlreadyOnTheDevice() {
    for theme in WeatherTheme.allCases {
        #expect(catalogueId(theme.icon) != nil, "\(theme.rawValue) named an installed icon")
    }
}

// Three of the eleven borrow a neighbour's picture, and it is a decision rather
// than an oversight: the catalogue has nothing of its own for them yet, and
// inventing an id means shipping whatever art happens to sit at that number.
// What keeps the three distinguishable on the clock is the overlay, which is a
// different firmware layer for each — the picture is not the only thing the
// device draws about the weather.
//
// Replacing one is a one-line edit here and a one-line edit in the table
// above, which is what makes new art a decision rather than a drift.
@Test func theThreeSkiesWithNoArtOfTheirOwnBorrowANeighboursPicture() {
    #expect(WeatherTheme.drizzle.icon == WeatherTheme.rain.icon)
    #expect(WeatherTheme.frost.icon == WeatherTheme.snow.icon)
    #expect(WeatherTheme.storm.icon == WeatherTheme.thunder.icon)

    // And the device still tells each pair apart, on the layer that draws over
    // everything rather than in the eight pixels beside the number.
    #expect(WeatherTheme.drizzle.overlay != WeatherTheme.rain.overlay)
    #expect(WeatherTheme.frost.overlay != WeatherTheme.snow.overlay)
    #expect(WeatherTheme.storm.overlay != WeatherTheme.thunder.overlay)

    // Eleven skies, eight pictures. Stated as a count so that a copy-paste that
    // gave a fourth sky somebody else's id fails here rather than on the clock.
    #expect(Set(WeatherTheme.allCases.compactMap { catalogueId($0.icon) }).count == 8)
}

// MARK: - The hour behind the reading

/// The night sky, written down separately from the constant that produces it —
/// the same reason the overlay names and the catalogue ids are each written
/// twice in this file. Derived, it would agree with any digit fumbled into the
/// constant, and a colour the firmware cannot parse is dropped in silence.
private let nightSky = "#000033"

// The complaint this answers, in the user's words: "cloudy by day is
// indistinguishable from cloudy by night". Nothing else on the app can carry
// the hour. The icon cannot — the catalogue has no cloud-at-night and no moon
// behind a cloud, and both LaMetric weather packs were swept whole to check.
// The text colour cannot — it is spent on how the temperature feels, which is a
// different question. That leaves the panel behind the text.
@Test func nightPutsAColourBehindTheReadingAndDayLeavesThePanelUnlit() {
    #expect(WeatherTheme.background(isDay: false) == nightSky)
    // Not a light colour by day — nothing at all. An unlit panel is what the
    // device does by default and what every other app in the loop looks like,
    // so a daytime tint would make the weather the odd one out in the rotation
    // for saying something the absence of a tint already says.
    #expect(WeatherTheme.background(isDay: true) == nil)
}

// The firmware takes six hex digits behind a hash and drops anything else
// without a word — the same silence `TemperatureColour` is written against. A
// malformed background is not an error anywhere; it is a panel that simply
// stays dark, which is indistinguishable from the daytime answer and so
// invisible in exactly the case this exists for.
@Test func theNightSkyIsAColourTheFirmwareParses() throws {
    let drawn = try #require(WeatherTheme.background(isDay: false))

    #expect(drawn.wholeMatch(of: #/#[0-9A-F]{6}/#) != nil, "drew \(drawn)")
}

// The generalisation, which is the reason the hour rides on the background
// rather than on a special case for overcast: EVERY sky is now drawn
// differently at night, not just the one that prompted the complaint.
//
// The hour is deliberately taken as an argument rather than read off a case.
// Only `clearDay`/`clearNight` split on it, and they split because the ICON had
// to — a sun and a moon are different pictures. Doubling all eleven cases to
// carry one boolean would produce twenty, nineteen of which draw their
// partner's icon over their partner's overlay.
@Test func everySkyIsDrawnDifferentlyByNightThanByDay() {
    for code in [0, 1, 2, 3, 45, 48, 51, 61, 71, 80, 95, 96, 4_242] {
        let byDay = (WeatherTheme(code: code, isDay: true).icon, WeatherTheme.background(isDay: true))
        let byNight = (
            WeatherTheme(code: code, isDay: false).icon, WeatherTheme.background(isDay: false)
        )

        #expect(byDay != byNight, "WMO \(code) is drawn identically at noon and at midnight")
    }
    // Overcast is what proves the difference comes from the background rather
    // than from the icon: it is ONE theme for both halves of the day — same
    // case, same picture, same overlay — which is exactly the complaint.
    #expect(WeatherTheme(code: 3, isDay: true) == WeatherTheme(code: 3, isDay: false))
}
