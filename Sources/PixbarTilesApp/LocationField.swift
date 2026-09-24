import PixbarKit
import Foundation
import SwiftUI

extension Coordinates {
    /// Where the weather is read from until somebody says otherwise.
    ///
    /// A default rather than nothing at all. A connector with no coordinates
    /// has nothing to ask about, so an unset location would mean a failure line
    /// on every poll until the user found the settings — and the app would have
    /// nothing to show for itself on the launch that is supposed to sell it.
    public static let `default` = Coordinates(latitude: 55.7558, longitude: 37.6173)
}

/// The place one clock's weather tile reads for.
///
/// Read on every produce rather than captured, so a place typed into the
/// settings takes effect at the next poll. The tile is looked up each time
/// for the same reason: it is the record, and a copy would go stale.
final class StoredLocation: @unchecked Sendable {
    private let defaults: UserDefaults
    private let clockId: UUID

    init(defaults: UserDefaults, clockId: UUID) {
        self.defaults = defaults
        self.clockId = clockId
    }

    var current: Coordinates { weatherTile?.config?.location ?? .default }

    /// Onto the tile, and only onto one that exists: saving a place is not a
    /// way to put back a weather tile the user took off the clock.
    func save(_ place: Coordinates) {
        guard let tile = weatherTile else { return }
        TileStore(defaults: defaults).update(tile) { $0.config = .weather(place) }
    }

    private var weatherTile: TileRecord? {
        TileStore(defaults: defaults).all().first {
            $0.key == TileKey(clockId: clockId, connectorId: WeatherConnector.appName)
        }
    }
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
    nonisolated static func text(for place: Coordinates) -> String {
        "\(place.latitude), \(place.longitude)"
    }

    /// Where the clock is, said the way somebody would say it: the country,
    /// the city, and the numbers in brackets behind them.
    ///
    /// The numbers stay rather than being replaced by the words. They are what
    /// the app actually reads the weather at, and a city is a single point —
    /// Moscow is about 40 km across — so a line that said only "Москва" would
    /// be rounder than the reading under it. The words go FIRST because they
    /// are what tells a reader whether the clock is pointed at the right place
    /// at all, which is a question two decimal numbers cannot answer.
    ///
    /// Either word may be missing: the geocoder returns places with no
    /// country, and a pair typed by hand has no name at all. Nothing is
    /// invented for the gap.
    nonisolated static func headline(name: String?, country: String?, place: Coordinates) -> String {
        let said = [country, name].compactMap { $0 }.joined(separator: ", ")
        guard said.isEmpty == false else { return text(for: place) }
        return "\(said) (\(text(for: place)))"
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
    static func save(_ typed: String, to place: StoredLocation) -> String {
        guard let parsed = parse(typed) else { return unreadable }
        place.save(parsed)
        return takesEffectAtTheNextPoll
    }
}

/// Finding the coordinates by name, so they do not have to be known as numbers.
///
/// A SEARCH rather than a "locate me" button, and that is the whole design
/// decision. IP geolocation was measured first: `ipwho.is` and `get.geojs.io`
/// both placed this machine in Amsterdam — 2,150 km from the desk the clock
/// sits on, because the connection is through a VPN — and neither hedged. A
/// button reading the network would have set the weather to another country
/// while looking exactly like it had worked. The accurate route is CoreLocation,
/// which an unsigned binary cannot use on this machine, so what is left is
/// asking the person who knows.
///
/// Its own object rather than fields on `AppModel`, because none of this is
/// settings: what was typed into the search box, what came back and what is
/// wrong with it all die when the sheet closes, while everything `AppModel`
/// holds outlives it. Only the chosen pair crosses over, and it crosses through
/// the same field a typed one does.
@MainActor
final class PlaceSearchModel: ObservableObject {
    /// Said when the geocoder placed nothing.
    ///
    /// Not "failed": this is measured behaviour, not an outage. The data is
    /// settlement-level, so a Moscow district — "Хамовники" — comes back HTTP
    /// 200 with no results, and calling that an error sends somebody hunting a
    /// network problem they do not have.
    static let nothingFound = "No place by that name. Try the town or city it is in."

    /// What this can and cannot find, said before it is met rather than after.
    ///
    /// Both halves are measured. "Хамовники" returns nothing at all, and
    /// "Митино" returns five villages in Вологодская and Кировская Областях
    /// rather than the Moscow district — so districts are not merely coarse
    /// here, they are wrong. And a settlement is ONE point: the user's own
    /// objection, that Moscow is about 40 km across and a front crosses it,
    /// is the reason the second clause exists.
    static let findsSettlementsNotAddresses =
        "Finds towns and cities, not addresses. A city district is not in this "
            + "data — searching for one finds a village elsewhere with the same "
            + "name — and a city is a single point: Moscow is about 40 km across, "
            + "so the reading is that point's weather, not your street's."

    /// What the name in the location box could mean. Empty until something is searched for, and
    /// emptied again the moment one is chosen or a search fails.
    @Published private(set) var candidates: [PlaceCandidate] = []
    /// Why there is nothing to choose from. Nil when there is.
    @Published private(set) var note: String?
    /// Whether a search is in flight, so the button can refuse a second one.
    @Published private(set) var isSearching = false

    /// Named `geocoder` where the parameter is named `search`, because the
    /// method below is `search()` and a property of that name would shadow it.
    private let geocoder: OpenMeteoPlaceSearch

    /// The shipped transport is built here rather than taken from `AppModel`,
    /// which does not hand its own out. Not free — but this is one object per
    /// opening of the settings, against a search that only ever fires on a
    /// keypress.
    init(
        search: OpenMeteoPlaceSearch = OpenMeteoPlaceSearch(transport: URLSessionTransport())
    ) {
        self.geocoder = search
    }

    /// The search waiting out the pause between two keystrokes.
    private var typing: Task<Void, Never>?

    /// What the box has in it now, on its way to becoming a search.
    ///
    /// The Find button is gone: a name box beside a button is a search
    /// somebody has to know to press, and what everybody already expects of a
    /// place field is that it offers places as they type. So this fires on
    /// every keystroke and is debounced here rather than at the field —
    /// "Москва" typed at speed is ONE request, for the whole word, not five
    /// for four prefixes nobody will ever see an answer to.
    ///
    /// An empty box puts the dropdown away rather than leaving the last
    /// answer hanging under a field that no longer says anything.
    func suggest(_ name: String, after delay: TimeInterval = 0.35) {
        typing?.cancel()
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            candidates = []
            note = nil
            return
        }
        typing = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard Task.isCancelled == false else { return }
            await self?.search(for: name)
        }
    }

    /// Asks the geocoder what `name` could mean, and says why when it is
    /// nothing.
    ///
    /// The name is passed in rather than held here, because it already lives in
    /// the location box: that box takes a pair OR a name, and a second field
    /// holding a copy of the same text would be two states to keep in step for
    /// no gain.
    ///
    /// Every exit clears `candidates` first. A failed second search that left
    /// the first one's rows on screen would offer a place belonging to a name
    /// the user has already replaced — the one way this surface could still put
    /// the weather somewhere nobody asked for.
    func search(for name: String) async {
        let asked = name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidates = []
        guard asked.isEmpty == false else {
            note = nil
            return
        }

        isSearching = true
        note = nil
        defer { isSearching = false }
        do {
            let found = try await geocoder.candidates(for: asked)
            candidates = found
            note = found.isEmpty ? Self.nothingFound : nil
        } catch {
            // The error's own words, because they separate the three failures a
            // user can act on differently: no network, the service refusing,
            // and something that is not the service answering at all.
            note = "Could not search: \(error.localizedDescription)"
        }
    }

    /// Puts the chosen pair into the location field.
    ///
    /// Through the field rather than around it: `AppModel.typedLocation` is
    /// what validates and saves, so choosing a row goes through exactly the
    /// checks and the "used at the next poll" note that typing does. This is a
    /// typing aid, not a second source of truth.
    func choose(_ candidate: PlaceCandidate, into field: Binding<String>) {
        field.wrappedValue = LocationField.text(for: candidate.coordinates)
        candidates = []
        note = nil
    }
}
