import Foundation
import Testing
@testable import PixbarKit

/// Real answers from the live geocoder, captured rather than invented.
///
/// Every literal below was taken from
/// `https://geocoding-api.open-meteo.com/v1/search?name=…&count=5&language=ru`
/// on 2026-08-19 and trimmed to the fields this package reads. The trimming is
/// the only edit: field names, nesting and the missing keys are as they arrived.
private enum Answered {
    /// Two of the five the geocoder returns for "Moscow": the capital, and the
    /// one in Idaho. THE reason this is a search rather than a button — a
    /// first-hit rule would put the weather 8000 km away for anybody who typed
    /// the English name of their own city.
    static let moscow = Data("""
    {"results":[
      {"id":524901,"name":"Москва","latitude":55.75204,"longitude":37.61781,
       "elevation":155.0,"feature_code":"PPLC","country_code":"RU",
       "timezone":"Europe/Moscow","population":10381222,"country":"Россия",
       "admin1":"Москва"},
      {"id":5601538,"name":"Москва","latitude":46.73239,"longitude":-117.00017,
       "elevation":786.0,"feature_code":"PPLA2","country_code":"US",
       "timezone":"America/Los_Angeles","population":25060,"country":"США",
       "admin1":"Айдахо","admin2":"Лейта"}],
     "generationtime_ms":0.2708435}
    """.utf8)

    /// What "Хамовники" — a Moscow district — actually comes back as. Note what
    /// is NOT here: no `results` key, no empty array, and HTTP **200**. A
    /// decoder that required the key would report a district it cannot place as
    /// a broken service.
    static let nothing = Data(#"{"generationtime_ms":0.8356571}"#.utf8)

    /// A candidate the geocoder gives no `admin1` for. Real: the tiny Москва in
    /// Тверская Область arrives without one, and so does every result for a
    /// place with no first-level division.
    static let unplaced = Data("""
    {"results":[
      {"id":2950159,"name":"Берлин","latitude":52.52437,"longitude":13.41053,
       "country_code":"DE","timezone":"Europe/Berlin","country":"Германия"}],
     "generationtime_ms":0.5452633}
    """.utf8)
}

@Test func theSearchAsksTheGeocoderForTheNameInTheReadersOwnLanguage() async throws {
    let transport = RecordingTransport()
    transport.body = Answered.moscow
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    _ = try await search.candidates(for: "Москва")

    let request = try #require(transport.requests.first)
    let url = try #require(request.url)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(request.httpMethod == "GET")
    #expect(url.absoluteString.hasPrefix("https://geocoding-api.open-meteo.com/v1/search?"))
    #expect(query.contains(URLQueryItem(name: "name", value: "Москва")))
    // The language is what makes the disambiguating line readable: without it
    // a Russian reader picks between "Russia" and "United States" instead of
    // "Россия" and "США". An unsupported code is not an error — the live
    // service answers a `language=xx` request in English, checked.
    #expect(query.contains(URLQueryItem(name: "language", value: "ru")))
    #expect(query.contains(URLQueryItem(
        name: "count", value: String(OpenMeteoPlaceSearch.candidateLimit)
    )))
}

@Test func theSearchReadsTheCandidatesTheGeocoderAnswersWith() async throws {
    let transport = RecordingTransport()
    transport.body = Answered.moscow
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    let found = try await search.candidates(for: "Москва")

    let capital = try #require(found.first)
    #expect(capital.name == "Москва")
    #expect(capital.coordinates == Coordinates(latitude: 55.75204, longitude: 37.61781))
    #expect(capital.region == "Москва")
    #expect(capital.country == "Россия")
}

// The whole reason this is a list. Both are called Москва, they are 8000 km
// apart, and only the line under the name tells them apart — so that line is
// what the test claims, not merely that two rows came back.
@Test func homonymsArriveAsSeparateCandidatesToldApartByRegionAndCountry() async throws {
    let transport = RecordingTransport()
    transport.body = Answered.moscow
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    let found = try await search.candidates(for: "Moscow")

    #expect(found.count == 2)
    #expect(found.map(\.name) == ["Москва", "Москва"])
    #expect(found.map(\.label) == ["Москва, Россия", "Айдахо, США"])
    #expect(found[1].coordinates == Coordinates(latitude: 46.73239, longitude: -117.00017))
    // Distinct ids, because four indistinguishable Митино come back for that
    // name and a list keyed on the label would collapse them into one row.
    #expect(found[0].id != found[1].id)
}

// Measured, not assumed: a name the geocoder cannot place answers HTTP 200 with
// the `results` key ABSENT. Reported as a failure it would send the user
// hunting a network problem they do not have; this is settlement-level data
// that simply does not carry city districts.
@Test func aNameTheGeocoderCannotPlaceIsNoCandidatesRatherThanAFailure() async throws {
    let transport = RecordingTransport()
    transport.body = Answered.nothing
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    #expect(try await search.candidates(for: "Хамовники").isEmpty)
}

@Test func aServerErrorIsReportedRatherThanReadAsNothingFound() async {
    let transport = RecordingTransport()
    // 400 rather than 503, because it is the one this endpoint really answers:
    // it rejects a malformed request with `{"reason":…,"error":true}`, a body
    // that decodes to no candidates if the status is not looked at first.
    transport.status = 400
    transport.body = Data(#"{"reason":"No value found at path 'name'.","error":true}"#.utf8)
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    await #expect(throws: PlaceSearchError.http(status: 400)) {
        _ = try await search.candidates(for: "Москва")
    }
}

// A captive portal answers 200 with a login page. Silence here leaves somebody
// pressing a button that does nothing, with no way to tell that from a slow
// network.
@Test func aBodyThatIsNotTheGeocodersJsonIsAFailureRatherThanSilence() async {
    let transport = RecordingTransport()
    transport.body = Data("<html><body>Sign in to continue</body></html>".utf8)
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    await #expect(throws: PlaceSearchError.unreadable) {
        _ = try await search.candidates(for: "Москва")
    }
}

// Half a line still separates homonyms — most of the ones that matter are in
// different countries.
@Test func aCandidateWithNoRegionIsLabelledByItsCountryAlone() async throws {
    let transport = RecordingTransport()
    transport.body = Answered.unplaced
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    let found = try #require(try await search.candidates(for: "Берлин").first)

    #expect(found.region == nil)
    #expect(found.label == "Германия")
}

// The live service answers a blank name with no results, so asking is a request
// spent to learn nothing — and this fires from a text field somebody is still
// typing into.
@Test func aBlankNameIsNotAskedAboutAtAll() async throws {
    let transport = RecordingTransport()
    transport.body = Answered.moscow
    let search = OpenMeteoPlaceSearch(transport: transport, language: "ru")

    #expect(try await search.candidates(for: "   ").isEmpty)
    #expect(transport.requests.isEmpty)
}
