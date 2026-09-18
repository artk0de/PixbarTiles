import Foundation

/// One place the geocoder offered, with enough beside it to tell it from its
/// homonyms.
///
/// A CANDIDATE, not an answer. "Moscow" returns the capital and a town of
/// 25,060 in Idaho, "Berlin" returns Germany and New Hampshire, and the
/// ordering that puts the big one first is the geocoder's courtesy rather than
/// a promise. Somebody has to choose, and the type says who.
public struct PlaceCandidate: Sendable, Equatable, Identifiable {
    /// The geonames id the geocoder returns.
    ///
    /// Carried because a list has to be keyed on something stable, and the
    /// visible text is not it: "Митино" returns four places in Вологодская
    /// Область whose name, region and country are character-for-character
    /// identical, and a list keyed on those would collapse them into one row.
    public let id: Int
    /// As the geocoder writes it in the language it was asked in — "Москва"
    /// for a `language=ru` search, "Moscow" for an English one, whichever
    /// script the query was typed in.
    public let name: String
    /// The first-level division: "Айдахо", "Вологодская Область". Optional
    /// because places with no such division come back without one.
    public let region: String?
    public let country: String?
    public let coordinates: Coordinates

    public init(
        id: Int, name: String, region: String?, country: String?, coordinates: Coordinates
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.country = country
        self.coordinates = coordinates
    }

    /// The line under the name that separates the homonyms — "Москва, Россия"
    /// against "Айдахо, США".
    ///
    /// Region first, because that is what differs when the country does not:
    /// most of the collisions inside one country are between regions, and the
    /// country is the coarser tiebreak rather than the finer one.
    public var label: String {
        [region, country].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum PlaceSearchError: Error, Sendable, Equatable {
    case http(status: Int)
    /// A body that is not the geocoder's JSON — a captive portal's login page
    /// is the one that actually happens, and it arrives with HTTP 200.
    case unreadable
}

extension PlaceSearchError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .http(status):
            return "geocoder -> HTTP \(status)"
        case .unreadable:
            return "the geocoder answered something that is not a place list"
        }
    }
}

extension PlaceSearchError: LocalizedError {
    /// Routed to `description` for the reason `WeatherError`'s is: whoever has
    /// to render an arbitrary `Error` reaches for `localizedDescription`, and
    /// the default there names an enum case number.
    public var errorDescription: String? { description }
}

/// Turns a typed place name into places to choose between.
///
/// Open-Meteo's own geocoder, so it is the same vendor the weather already
/// comes from: no key, no signup, no new dependency, and coordinates that are
/// meant for the endpoint they will be handed to.
///
/// What it is NOT is a way to find where this machine is. IP geolocation was
/// tried first and measured: `ipwho.is` and `get.geojs.io` both placed this
/// machine in Amsterdam, 2,150 km from the desk the clock is on, because the
/// connection is through a VPN — and they said so with the same confidence they
/// would have used if they were right. A wrong answer delivered silently is
/// worse than no answer, so the surface asks instead of guessing.
///
/// A plain struct rather than an actor, unlike `OpenMeteoSource`: there is
/// nothing to remember between calls. The weather is polled on a schedule and
/// has to be rate-limited against itself; this fires when somebody presses a
/// key, and the answer is stale the moment they type another letter.
public struct OpenMeteoPlaceSearch: Sendable {
    public static let endpoint = "https://geocoding-api.open-meteo.com/v1/search"

    /// How many places to offer.
    ///
    /// Five, because that is what it takes to get past the homonyms that
    /// matter: an English "Moscow" search returns the capital, Idaho, Moscow
    /// Mills in Missouri, the Pennsylvania borough and one more before the
    /// list stops being about Moscow at all. Fewer would cut the tail off a
    /// name like "Митино", where all five hits are different villages.
    public static let candidateLimit = 5

    /// What the reader's own Mac is set to, so the disambiguating line arrives
    /// in a language they can disambiguate with.
    ///
    /// Not whitelisted against the codes Open-Meteo documents, because the live
    /// service does not need it to be: a `language=xx` request comes back
    /// HTTP 200 in English, checked. A whitelist here would be a list to keep
    /// in step with somebody else's service for no gain.
    public static var systemLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private let transport: any Transport
    private let language: String

    public init(
        transport: any Transport, language: String = OpenMeteoPlaceSearch.systemLanguage
    ) {
        self.transport = transport
        self.language = language
    }

    /// The places that name could mean, best first.
    ///
    /// Empty is an ANSWER, not a failure, and the distinction is the whole
    /// reason the return type is not optional: the geocoder holds settlements,
    /// so a Moscow district like "Хамовники" comes back HTTP 200 with no
    /// results at all. Reported as an error that would send somebody hunting a
    /// network problem they do not have.
    public func candidates(for name: String) async throws -> [PlaceCandidate] {
        let asked = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank box answers nothing on the live service too, so asking is a
        // request spent to learn that — and this fires from a field somebody is
        // still typing into.
        guard asked.isEmpty == false else { return [] }

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "name", value: asked),
            URLQueryItem(name: "count", value: String(Self.candidateLimit)),
            URLQueryItem(name: "language", value: language),
        ]
        // Force-unwrapped for the reason `AnecdoteSource.topFeed` is: the
        // endpoint is a literal that parses and `URLComponents` percent-encodes
        // the name itself, so no input reaches nil here. An error case for it
        // would be a branch no test could ever enter, which is a claim rather
        // than a safeguard.
        var request = URLRequest(url: components!.url!)
        request.httpMethod = "GET"

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PlaceSearchError.http(status: response.statusCode)
        }
        guard let answer = try? JSONDecoder().decode(Places.self, from: data) else {
            throw PlaceSearchError.unreadable
        }
        return answer.candidates
    }
}

/// The response, as the geocoder shapes it.
private struct Places: Decodable {
    /// Optional because the key is OMITTED — not emptied — for a name the
    /// geocoder cannot place: `{"generationtime_ms":0.83}` at HTTP 200,
    /// verified against the live service. A non-optional array would decode
    /// that as malformed and report "not found" as a broken service.
    let results: [Match]?

    struct Match: Decodable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        /// The geocoder's name for the first-level division. Read under its own
        /// key rather than renamed to `region` in the JSON sense — `admin1` is
        /// what arrives, and `admin2`/`admin3` beside it are the finer ones
        /// this does not use.
        let admin1: String?
        let country: String?
    }

    var candidates: [PlaceCandidate] {
        (results ?? []).map {
            PlaceCandidate(
                id: $0.id,
                name: $0.name,
                region: $0.admin1,
                country: $0.country,
                coordinates: Coordinates(latitude: $0.latitude, longitude: $0.longitude)
            )
        }
    }
}
