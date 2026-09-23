import AppKit
import PixelClockKit
import Foundation
import SwiftUI
import Testing
@testable import PixelClockTilesApp

/// Two of the five the live geocoder returns for "Moscow", captured on
/// 2026-08-19 and trimmed to the fields this package reads: the capital, and
/// the one in Idaho.
private let twoMoscows = Data("""
{"results":[
  {"id":524901,"name":"Москва","latitude":55.75204,"longitude":37.61781,
   "country_code":"RU","population":10381222,"country":"Россия","admin1":"Москва"},
  {"id":5601538,"name":"Москва","latitude":46.73239,"longitude":-117.00017,
   "country_code":"US","population":25060,"country":"США","admin1":"Айдахо"}],
 "generationtime_ms":0.2708435}
""".utf8)

/// What a name the geocoder cannot place really answers with: HTTP 200 and no
/// `results` key at all.
private let placedNowhere = Data(#"{"generationtime_ms":0.8356571}"#.utf8)

@MainActor
private func searching(_ body: Data, status: Int = 200) -> PlaceSearchModel {
    PlaceSearchModel(
        search: OpenMeteoPlaceSearch(
            transport: StubTransport(status: status, body: body), language: "ru"
        )
    )
}

// The point of the whole surface: the pair the user picked is the pair the
// weather reads, and it arrives through the SAME field a typed one does — so
// saving, validation and the "used at the next poll" note are the ones already
// shipped rather than a second path that has to be kept in step.
@Test @MainActor func choosingACandidateFillsTheLocationFieldWithTextThatFieldParsesBack() async {
    let places = searching(twoMoscows)
    var field = "55.7558, 37.6173"
    await places.search(for: "Moscow")
    let idaho = places.candidates[1]
    places.choose(idaho, into: Binding(get: { field }, set: { field = $0 }))

    #expect(LocationField.parse(field) == idaho.coordinates)
    #expect(field == "46.73239, -117.00017")
    // The list goes away with the choice: leaving it up invites a second pick
    // over a search the user has already answered.
    #expect(places.candidates.isEmpty)
}

// Failure is visible or it is not failure. A button that leaves the box empty
// and says nothing is indistinguishable from one whose press did not register.
@Test @MainActor func aFailedSearchSaysWhatWentWrongRatherThanShowingNoCandidates() async {
    let places = searching(Data("<html>Sign in to continue</html>".utf8))
    await places.search(for: "Москва")

    #expect(places.candidates.isEmpty)
    #expect(places.note != nil)
    #expect(places.note != PlaceSearchModel.nothingFound)
}

// Measured against the live geocoder: "Хамовники" — a Moscow district — comes
// back HTTP 200 with no results. That is not an outage, and saying "failed"
// would send somebody hunting a network problem they do not have. It is the
// data being settlement-level, which is what the note has to explain.
@Test @MainActor func aNameThatMatchesNothingSaysSoRatherThanSilence() async {
    let places = searching(placedNowhere)
    await places.search(for: "Хамовники")

    #expect(places.candidates.isEmpty)
    #expect(places.note == PlaceSearchModel.nothingFound)
}

// A second search that fails must not leave the first one's answers on screen:
// picking a row from a list that belongs to a name you have already replaced is
// how the weather ends up somewhere nobody asked for.
@Test @MainActor func aFailedSearchDropsTheCandidatesTheLastOneFound() async {
    let transport = SwitchableTransport(body: twoMoscows)
    let places = PlaceSearchModel(
        search: OpenMeteoPlaceSearch(transport: transport, language: "ru")
    )
    await places.search(for: "Moscow")
    #expect(places.candidates.count == 2)

    // The network going away between two searches, which is what a laptop lid
    // does — not a status code the service chose to send.
    transport.nowFails()
    await places.search(for: "Zelenograd")

    #expect(places.candidates.isEmpty)
    #expect(places.note != nil)
}

// The search is a typing aid and nothing else: it writes only when a row is
// picked. So a search that fails AFTER one was picked leaves the chosen pair
// exactly where it is — it does not clear the field, and it does not put the
// previous value back.
@Test @MainActor func aFailedSearchLeavesTheLocationAlreadyChosenExactlyAsItWas() async {
    let transport = SwitchableTransport(body: twoMoscows)
    let places = PlaceSearchModel(
        search: OpenMeteoPlaceSearch(transport: transport, language: "ru")
    )
    var field = "55.7558, 37.6173"
    let box = Binding(get: { field }, set: { field = $0 })
    await places.search(for: "Moscow")
    places.choose(places.candidates[0], into: box)

    transport.nowFails()
    await places.search(for: "Zelenograd")

    #expect(field == "55.75204, 37.61781")
    #expect(LocationField.parse(field) == Coordinates(latitude: 55.75204, longitude: 37.61781))
    #expect(places.note != nil)
}

// The user must be told what this can and cannot find BEFORE they meet it:
// a district is not in the data, and a city is one point in a place that is
// tens of kilometres across.
@Test @MainActor func theSurfaceSaysTheSearchFindsSettlementsRatherThanAddresses() {
    let said = PlaceSearchModel.findsSettlementsNotAddresses

    #expect(said.contains("district"))
    #expect(said.contains("40 km"))
}

// The candidates-reaching-the-screen test drew `WeatherSettings`, which the
// switch-over took off the general settings (D8): the place search's surface
// is OWED a new home beside the weather tile's own block, and the model tests
// above are what stays pinned until it lands.

// MARK: - How a place is said

// Country first, then the city, then the numbers in brackets. The numbers stay
// because they are what the app actually reads the weather at and a city is a
// single point; the words go first because they are what tells a reader
// whether the clock is pointed at the right place at all.
@Test func aChosenPlaceIsSaidAsCountryThenCityThenTheNumbers() {
    let said = LocationField.headline(
        name: "Москва", country: "Россия",
        place: Coordinates(latitude: 55.7558, longitude: 37.6173)
    )

    #expect(said == "Россия, Москва (55.7558, 37.6173)")
}

// A pair typed by hand has no name to say, and inventing one would be the
// surface claiming to know something it does not.
@Test func aTypedPlaceIsSaidAsItsNumbersAlone() {
    let said = LocationField.headline(
        name: nil, country: nil,
        place: Coordinates(latitude: 55.7558, longitude: 37.6173)
    )

    #expect(said == "55.7558, 37.6173")
}

// Half a name is still a name. The geocoder returns places with no country and
// places with no region, so the line has to hold together missing either.
@Test func aPlaceWithHalfANameSaysTheHalfItHas() {
    let noCountry = LocationField.headline(
        name: "Москва", country: nil, place: Coordinates(latitude: 1, longitude: 2)
    )
    let noCity = LocationField.headline(
        name: nil, country: "Россия", place: Coordinates(latitude: 1, longitude: 2)
    )

    #expect(noCountry == "Москва (1.0, 2.0)")
    #expect(noCity == "Россия (1.0, 2.0)")
}
