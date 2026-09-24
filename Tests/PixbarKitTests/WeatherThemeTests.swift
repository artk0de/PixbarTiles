import Foundation
import Testing
@testable import PixbarKit

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

// And the split reaches every cloud-shaped sky, not only the ones with a sun
// behind them.
//
// Overcast used to be the exception here, on the reasoning that there is no sun
// behind it to have set. True about the sky and wrong about the display: an
// overcast midnight still does not look like an overcast noon, and the reason
// the two were one theme was that nothing could draw them apart. Something can
// now, so the exception is gone.
@Test func everyCloudySkyIsAlsoDrawnDifferentlyByNight() {
    #expect(WeatherTheme(code: 2, isDay: true) != WeatherTheme(code: 2, isDay: false))
    #expect(WeatherTheme(code: 3, isDay: true) != WeatherTheme(code: 3, isDay: false))
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

// And it now has a night half, which it did not before. The earlier asymmetry
// was recorded here as a decision — the catalogue has no moon behind a cloud,
// both weather packs having been swept whole to check, so the branch would have
// drawn the same moon as `clearNight` and nobody could ever have seen it. That
// premise died: art for both night skies arrived from outside the catalogue and
// now ships with this app, so the two are drawn apart and the branch is worth
// having. What has NOT changed is the test that would catch a regression to a
// bare moon on a cloudy night.
@Test func aPartlyCloudyNightIsItsOwnSkyNowThatSomethingCanDrawIt() {
    #expect(WeatherTheme(code: 2, isDay: false) == .partlyCloudyNight)
    #expect(WeatherTheme(code: 2, isDay: true) == .partlyCloudyDay)

    // Overcast splits the same way and for the same reason: an overcast noon
    // and an overcast midnight drew one identical picture until there was a
    // second one to draw.
    #expect(WeatherTheme(code: 3, isDay: true) == .cloudDay)
    #expect(WeatherTheme(code: 3, isDay: false) == .cloudNight)

    // Each night sky draws its own picture. The regression this guards is the
    // one the user reported twice: a cloudy night that looks exactly like a
    // clear night, or exactly like a cloudy noon.
    #expect(WeatherTheme.partlyCloudyNight.icon != WeatherTheme.clearNight.icon)
    #expect(WeatherTheme.cloudNight.icon != WeatherTheme.cloudDay.icon)
    #expect(WeatherTheme.cloudNight.icon != WeatherTheme.partlyCloudyNight.icon)

    // The codes either side of it are untouched in both lighting conditions: 0
    // and 1 are a bare sun or a bare moon, which is what they look like.
    #expect(WeatherTheme(code: 0, isDay: true) == .clearDay)
    #expect(WeatherTheme(code: 1, isDay: true) == .clearDay)
    #expect(WeatherTheme(code: 0, isDay: false) == .clearNight)
    #expect(WeatherTheme(code: 1, isDay: false) == .clearNight)
}

// A night sky reaches for `clear` like every other cloud-shaped sky, and that is
// not an oversight the new cases introduced: the firmware has no night layer and
// no cloud layer. Probed against the clock on 2026-08-20 — `fog`, `cloud`,
// `cloudy`, `night`, `wind`, `hail` and `sun` are all coerced to `clear`, while
// `frost` and `thunder` written in the same pass came back verbatim. So the
// picture is the only thing that can carry the difference, which is why the art
// had to exist before the branch could.
@Test func theNightSkiesDrawTheirDifferenceInPixelsBecauseNoLayerCarriesIt() {
    #expect(WeatherTheme.partlyCloudyNight.overlay == .clear)
    #expect(WeatherTheme.cloudNight.overlay == .clear)
    #expect(WeatherTheme.cloudDay.overlay == .clear)
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

/// The picture each sky draws, written down here separately from the type that
/// carries them — the same reason the overlay names are written twice. A table
/// compared against itself agrees with any typo introduced into it.
///
/// This is also the record of what was verified: every entry below cost a
/// download and a look at its frames, and all of them are 8x8 animated GIFs,
/// which is the only thing the device draws.
///
/// Two of them are `.bundled` rather than `.catalogue`, and that is what a sky
/// with no catalogue art looks like. The catalogue has no public search — the
/// firmware's own icon page only previews by id, checked on 2026-08-20 — so the
/// two night skies could not be found there and their art ships inside this app
/// instead. `.installed` is still the one thing no sky may name: see below.
private let verifiedIcons: [WeatherTheme: IconReference] = [
    .clearDay: .catalogue(2282),
    .clearNight: .catalogue(12181),
    .partlyCloudyDay: .catalogue(53802),
    .partlyCloudyNight: .bundled("PartlyCloudyNightHalfMoon"),
    .cloudDay: .catalogue(53384),
    .cloudNight: .bundled("ani_partly_cloudy_night"),
    .fog: .catalogue(17056),
    .drizzle: .catalogue(2284),
    .rain: .catalogue(2284),
    .snow: .catalogue(2289),
    .frost: .catalogue(2289),
    .thunder: .catalogue(49299),
    .storm: .catalogue(49299),
]

/// The id inside a catalogue reference, or nil for art that comes from anywhere
/// else.
private func catalogueId(_ reference: IconReference) -> Int? {
    guard case let .catalogue(id) = reference else { return nil }
    return id
}

@Test func everySkyDrawsThePictureThatWasVerifiedForIt() throws {
    // A sky added without an entry would otherwise reach the device drawing
    // whatever its neighbour draws, which is the one failure this file exists
    // to catch: the clock shows a picture either way.
    #expect(verifiedIcons.count == WeatherTheme.allCases.count)

    for theme in WeatherTheme.allCases {
        let picture = try #require(verifiedIcons[theme], "no verified icon for \(theme.rawValue)")

        #expect(theme.icon == picture, "\(theme.rawValue) drew \(theme.icon)")
    }
}

// No sky names a picture it cannot put there itself. `.installed` is a promise
// about a device this app has never listed — on a clock that has never run it,
// or on one that has been reset, the app draws no picture at all and nothing
// anywhere says why. `.catalogue` downloads its bytes and `.bundled` carries
// them, so both keep the promise; `.installed` is the case that does not, and
// it stays reserved for art a user placed on their own flash.
@Test func noSkyAssumesItsPictureIsAlreadyOnTheDevice() {
    for theme in WeatherTheme.allCases {
        if case .installed = theme.icon {
            Issue.record("\(theme.rawValue) named an installed icon")
        }
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

    // Thirteen skies, ten pictures: eight ids from the catalogue and two that
    // ship here. Stated as counts so that a copy-paste which gave a fourth sky
    // somebody else's picture fails here rather than on the clock.
    #expect(Set(WeatherTheme.allCases.compactMap { catalogueId($0.icon) }).count == 8)
    #expect(Set(WeatherTheme.allCases.compactMap { bundledName($0.icon) }).count == 2)
}

/// The name inside a bundled reference, or nil for art from anywhere else.
private func bundledName(_ reference: IconReference) -> String? {
    guard case let .bundled(name) = reference else { return nil }
    return name
}

// The bytes behind every `.bundled` name, checked to be there and to be what
// the clock can draw.
//
// This is the test that makes `.bundled` worth more than `.installed`: the
// promise is only kept if the art is genuinely inside the app, so a resource
// dropped from the package — or renamed on one side only — has to fail here.
// The device would answer a missing icon by drawing the app with nothing beside
// it, which reads as an ordinary banner and reports nothing at all.
@Test func everyBundledSkyCarriesItsOwnEightByEightAnimation() throws {
    for theme in WeatherTheme.allCases {
        guard let name = bundledName(theme.icon) else { continue }

        let blob = try #require(
            BundledIcon.data(named: name),
            "\(theme.rawValue) names bundled art \(name) that is not in the package"
        )

        // GIF89a rather than GIF87a: only the later version carries animation,
        // and a static picture beside a moving one is the drift worth catching.
        #expect(blob.starts(with: Data("GIF89a".utf8)), "\(name) is not an animated GIF")
        // Width and height live little-endian at offsets 6 and 8. Eight by
        // eight is the whole matrix an icon gets.
        #expect(Int(blob[6]) | Int(blob[7]) << 8 == 8, "\(name) is not 8 wide")
        #expect(Int(blob[8]) | Int(blob[9]) << 8 == 8, "\(name) is not 8 tall")
    }
}
