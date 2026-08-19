import AwtrixKit
import Foundation

extension Coordinates {
    /// Where the weather is read from until somebody says otherwise.
    ///
    /// A default rather than nothing at all. A connector with no coordinates
    /// has nothing to ask about, so an unset location would mean a failure line
    /// on every poll until the user found the settings — and the app would have
    /// nothing to show for itself on the launch that is supposed to sell it.
    public static let `default` = Coordinates(latitude: 55.7558, longitude: 37.6173)

    /// One key holding the pair, rather than two holding halves of it. A
    /// latitude saved without its longitude is not half a location; it is a
    /// different place.
    static let storageKey = "weatherLocation"

    static func stored(in defaults: UserDefaults) -> Coordinates {
        guard
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(Coordinates.self, from: data)
        else { return .default }
        return saved
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Reads the stored location, from wherever the connector happens to ask.
///
/// A holder rather than a `UserDefaults` captured directly in the connector's
/// location closure: that closure is `@Sendable` and `UserDefaults` is not, so
/// the capture is refused under strict concurrency. `@unchecked` is not a
/// waiver — `UserDefaults` is documented as thread-safe, and this reads one key
/// and holds nothing — and it is the same conformance `UserDefaultsSettingsStore`
/// carries for the same reason.
final class StoredLocation: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Read on every call rather than cached, so a pair typed into the settings
    /// takes effect at the next poll instead of at the next launch.
    var current: Coordinates { Coordinates.stored(in: defaults) }
}

/// Where the clock is, as the settings write it.
///
/// Typed rather than asked for. CoreLocation was probed on this machine first:
/// an unsigned binary calling `requestWhenInUseAuthorization` stays at
/// `.notDetermined` and `requestLocation` comes back `kCLErrorDenied` — the
/// same silence `UNUserNotificationCenter` and `INFocusStatusCenter` already
/// answer with here. A desk clock does not travel either, so the coordinates
/// are set once, and asking for location access on first launch of a menu bar
/// toy is how an app gets denied everything.
///
/// Its own type rather than a closure in the view, for the reason
/// `DeviceHostField` is one: the rules that make it safe — two numbers, both on
/// the globe, and nothing saved otherwise — are behaviour, and a `TextField`'s
/// action closure is not somewhere behaviour can be read back from.
@MainActor
enum LocationField {
    /// Said after a save. Unlike the address, this takes effect at the next
    /// poll rather than at the next launch: the connector reads the stored pair
    /// every time it produces.
    static let takesEffectAtTheNextPoll = "Saved — used at the next poll"

    /// Said instead, when what was typed is not a place.
    ///
    /// The example is the answer as much as the complaint: "invalid" leaves
    /// somebody guessing whether the separator, the order or the sign is what
    /// this app wanted.
    static let unreadable = "Two numbers, latitude first — for example 55.7558, 37.6173"

    /// What a stored pair looks like in the box, and a string this field
    /// accepts back.
    static func text(for place: Coordinates) -> String {
        "\(place.latitude), \(place.longitude)"
    }

    /// Two numbers, or nothing.
    ///
    /// Range-checked here rather than left to the service. Open-Meteo answers
    /// 400 for a latitude off the globe, which would reach the user as a failed
    /// poll a quarter of an hour after they typed it, on a different surface,
    /// with nothing to connect the two.
    static func parse(_ typed: String) -> Coordinates? {
        let parts = typed.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2,
            let latitude = Double(parts[0]), let longitude = Double(parts[1]),
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return Coordinates(latitude: latitude, longitude: longitude)
    }

    /// Stores a typed location, and answers what to say about it.
    ///
    /// Never nil, where `DeviceHostField.save` answers nil for a blank: there
    /// the field is one of two places the address appears and silence reads as
    /// "nothing happened", while here an unparseable pair is the ONLY thing
    /// standing between the user and a connector that quietly reports the
    /// weather somewhere else.
    @discardableResult
    static func save(_ typed: String, to defaults: UserDefaults) -> String {
        guard let place = parse(typed) else { return unreadable }
        place.save(to: defaults)
        return takesEffectAtTheNextPoll
    }
}
