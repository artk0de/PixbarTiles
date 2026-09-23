import CoreLocation
import Foundation
import PixelClockKit

/// What a pair of coordinates is CALLED.
///
/// The search knows the answer for a place somebody picked from it, and that
/// is the easy half. The hard half is every other place: a pair typed into the
/// box, and — the one that actually matters — every tile that already exists,
/// stored as two numbers years before a name was kept beside them. Those
/// showed "55.7558, 37.6173" and nothing else, which is the whole complaint
/// the headline was built to answer.
protocol PlaceNaming: Sendable {
    /// The city and the country at these coordinates, either or both nil when
    /// the answer is not available. Never throws: a name is an improvement on
    /// a surface that works without one, and an error here must not reach a
    /// user who did not ask a question.
    func name(of place: Coordinates) async -> (name: String?, country: String?)
}

/// The shipped one: CoreLocation's reverse geocoder.
///
/// Reverse geocoding needs no location authorization — it is a lookup of
/// coordinates the caller already has, not a reading of where this Mac is.
/// That distinction is why this can be used where `requestLocation` could
/// not: an unsigned binary asking where it IS gets `kCLErrorDenied` on this
/// machine, while asking what a pair of numbers is called is answered.
///
/// Apple's service rate-limits per app, which is the reason the answer is
/// SAVED onto the tile rather than asked again on every opening of the
/// window: a tile is named once, and a tile whose place never moves is never
/// looked up twice.
struct CoreLocationPlaceNaming: PlaceNaming {
    func name(of place: Coordinates) async -> (name: String?, country: String?) {
        let found = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: place.latitude, longitude: place.longitude)
        )
        guard let mark = found?.first else { return (nil, nil) }
        // The most specific name that is still a PLACE: a locality, else the
        // district or region around it. A thoroughfare would name a street,
        // which is finer than the weather this is labelling — the reading is
        // a settlement's, and a street name beside it would promise a
        // precision the forecast does not have.
        let name = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea
        return (name, mark.country)
    }
}

/// Names nothing, which is what the tests and any surface with no business
/// going to the network use. The headline falls back to the coordinates, as
/// it does for a place the geocoder cannot name either.
struct NoPlaceNaming: PlaceNaming {
    func name(of place: Coordinates) async -> (name: String?, country: String?) { (nil, nil) }
}
