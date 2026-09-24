import Foundation

/// Where the clock is.
///
/// A pair the user types rather than a place the app asks for. A desk clock
/// does not travel, so the coordinates are set once; and demanding location
/// access on first launch of a menu bar toy is how an app gets denied
/// everything, including the permissions it actually needs.
public struct Coordinates: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// What the sky is doing right now, as Open-Meteo reports it.
public struct WeatherReading: Sendable, Equatable {
    /// A WMO present-weather code. `WeatherTheme` is what turns it into
    /// something the clock can draw.
    public let code: Int
    /// Whether the sun is up where the clock is. Arrives as 1 or 0 rather than
    /// as a JSON boolean.
    public let isDay: Bool
    /// Degrees Celsius.
    public let temperature: Double
    /// What those degrees feel like, in degrees Celsius — wind, humidity and
    /// sun folded in by the service. What the reading is COLOURED from, while
    /// the digits stay the air temperature: a clock showing 2° when every other
    /// thermometer in the room says 7 reads as broken rather than as informed.
    ///
    /// Optional for the reason `interval` is: a response that stops carrying it
    /// has to read as "no answer for that" rather than fail the whole poll, and
    /// the air temperature is a fair second answer to colour from.
    public let apparentTemperature: Double?
    /// Millimetres in the last hour.
    public let precipitation: Double
    /// Kilometres per hour.
    public let windSpeed: Double
    /// How often the service says this value changes — 900 seconds live.
    ///
    /// Carried on the reading rather than assumed, because it is the poll
    /// cadence: this is a free public service and the weather does not move
    /// faster than its own updates.
    public let interval: TimeInterval

    /// Percent of relative humidity, as the service reports it — the weather
    /// tile's optional second line. Optional like `apparentTemperature`: a
    /// response that stops carrying it reads as "no answer for that", and a
    /// tile asked to show humidity with no answer shows the temperature alone.
    public let relativeHumidity: Double?

    // The TC002 face's details. Every one is optional for the reason
    // `apparentTemperature` is, and more so: each feeds one line of a rotation,
    // so a response that stops carrying it drops that line rather than the
    // poll. Defaulted in `init` so every reading built before the face existed
    // still reads as the reading it was.

    /// Degrees the wind comes FROM, as the service reports it. The face's arrow
    /// points the other way, where the air goes.
    public let windDirection: Double?
    /// Kilometres per hour, like `windSpeed` — the service's unit. The face
    /// converts to the tile's unit; thresholds are compared in m/s.
    public let windGusts: Double?
    public let uvIndex: Double?
    /// Today's daily maximum and minimum, degrees Celsius — "today" as the
    /// service's local day at the place, which `timezone=auto` asks for.
    public let todayHigh: Double?
    public let todayLow: Double?
    /// Today's and tomorrow's sunrise and sunset, in that order. Empty when
    /// the answer carries no daily block. Tomorrow's is what "the next sun
    /// event" becomes once today's sunset has passed.
    public let sunrises: [Date]
    public let sunsets: [Date]
    /// The hourly series from the start of the place's today, by time. Empty
    /// when absent.
    public let hourly: [HourlyPoint]

    /// One hour of the forecast.
    public struct HourlyPoint: Sendable, Equatable {
        /// The start of the hour.
        public let time: Date
        /// Degrees Celsius.
        public let temperature: Double
        /// Percent. `nil` when the service has no answer for the hour — which
        /// is "unknown", not a dry hour, so it never reads as zero.
        public let precipitationProbability: Int?

        public init(time: Date, temperature: Double, precipitationProbability: Int?) {
            self.time = time
            self.temperature = temperature
            self.precipitationProbability = precipitationProbability
        }
    }

    public init(
        code: Int, isDay: Bool, temperature: Double, apparentTemperature: Double? = nil,
        precipitation: Double, windSpeed: Double, interval: TimeInterval,
        relativeHumidity: Double? = nil,
        windDirection: Double? = nil, windGusts: Double? = nil, uvIndex: Double? = nil,
        todayHigh: Double? = nil, todayLow: Double? = nil,
        sunrises: [Date] = [], sunsets: [Date] = [], hourly: [HourlyPoint] = []
    ) {
        self.code = code
        self.isDay = isDay
        self.temperature = temperature
        self.apparentTemperature = apparentTemperature
        self.precipitation = precipitation
        self.windSpeed = windSpeed
        self.interval = interval
        self.relativeHumidity = relativeHumidity
        self.windDirection = windDirection
        self.windGusts = windGusts
        self.uvIndex = uvIndex
        self.todayHigh = todayHigh
        self.todayLow = todayLow
        self.sunrises = sunrises
        self.sunsets = sunsets
        self.hourly = hourly
    }
}

public enum WeatherError: Error, Sendable, Equatable {
    case invalidLocation(Coordinates)
    case http(status: Int)
}

extension WeatherError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidLocation(place):
            return "invalid location: \(place.latitude), \(place.longitude)"
        case let .http(status):
            return "open-meteo -> HTTP \(status)"
        }
    }
}

extension WeatherError: LocalizedError {
    /// Routed to `description` for the reason `AwtrixError`'s is: whoever has
    /// to render an arbitrary `Error` reaches for `localizedDescription`, and
    /// the default there names an enum case number.
    public var errorDescription: String? { description }
}

/// The current weather, from a service that needs no key, no signup and no
/// dependency — a plain GET returning the WMO code and the readings beside it.
///
/// An actor because it remembers its last answer. The remembering is the point:
/// the schedule's interval belongs to the user, who may drag it down to a
/// minute, and this must not turn that into a request a minute against a free
/// public API for a value that changes every fifteen.
public actor OpenMeteoSource {
    /// The floor a first call uses, before there is a response to read the real
    /// cadence off. The live service answers 900.
    public static let defaultInterval: TimeInterval = 900

    public static let endpoint = "https://api.open-meteo.com/v1/forecast"

    /// The fields the request asks for, verified against the live service.
    /// `apparent_temperature` arrives in the same `current` object as the air
    /// temperature and costs nothing extra to ask for — one request answers
    /// both the digits and the colour. `relative_humidity_2m` is the weather
    /// tile's own answer: a tile told to show humidity draws it from the same
    /// request rather than paying a second one.
    ///
    /// The last three are the TC002 face's wind arrow, gust note and UV line.
    public static let fields =
        "weather_code,is_day,precipitation,temperature_2m,apparent_temperature,"
            + "wind_speed_10m,relative_humidity_2m,wind_direction_10m,wind_gusts_10m,uv_index"

    /// The face's hourly chart and rain window: a temperature and a chance of
    /// rain per hour.
    public static let hourlyFields = "temperature_2m,precipitation_probability"

    /// The face's hi/lo line and its sunrise/sunset line, for today and
    /// tomorrow — tomorrow's sunrise is the next sun event after tonight's
    /// sunset.
    public static let dailyFields = "temperature_2m_max,temperature_2m_min,sunrise,sunset"

    private let transport: any Transport
    /// Injected so a test can step over a quarter of an hour rather than wait
    /// one out. The shipped value is the only one that reads the clock.
    private let now: @Sendable () -> Date
    /// The last answer for each place, and when it was given.
    ///
    /// Keyed by the place rather than holding one answer. One slot served the
    /// app while there was one location; two weather tiles at two places would
    /// evict each other on every poll, and each would fetch on every run
    /// however fresh the other's answer was.
    private var cached: [Coordinates: (reading: WeatherReading, at: Date)] = [:]

    public init(transport: any Transport, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    /// What the sky is doing at these coordinates, fetching only when the last
    /// answer has aged past the cadence that answer itself declared.
    public func reading(at place: Coordinates) async throws -> WeatherReading {
        if let hit = cached[place], now().timeIntervalSince(hit.at) < hit.reading.interval {
            return hit.reading
        }

        let reading = try await fetch(place)
        // Written only on success, so one outage is not served as the weather
        // for the whole of the next interval.
        cached[place] = (reading, now())
        return reading
    }

    private func fetch(_ place: Coordinates) async throws -> WeatherReading {
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: Self.fields),
            URLQueryItem(name: "hourly", value: Self.hourlyFields),
            URLQueryItem(name: "daily", value: Self.dailyFields),
            // Epoch seconds rather than local date strings, so no time has to
            // be parsed in a zone the app would have to guess; `auto` makes the
            // daily buckets the place's own days, so "today's high" is the
            // place's today; two days, because after sunset the next sun event
            // is tomorrow's sunrise and the hourly chart runs past midnight.
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        guard let url = components?.url else { throw WeatherError.invalidLocation(place) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw WeatherError.http(status: response.statusCode)
        }
        return try JSONDecoder().decode(Forecast.self, from: data).reading
    }
}

/// The response, as the service shapes it: everything under a `current` object
/// that carries its own update interval beside the readings.
///
/// `hourly` and `daily` are optional containers of parallel arrays, one array
/// per field asked for; each is decoded with `decodeIfPresent` so an answer
/// that drops one drops the details built from it, not the poll.
private struct Forecast: Decodable {
    let current: Current
    let hourly: Hourly?
    let daily: Daily?

    struct Hourly: Decodable {
        let time: [Double]?
        let temperature: [Double]?
        /// `null` inside the array is an hour without an answer.
        let precipitationProbability: [Int?]?

        private enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case precipitationProbability = "precipitation_probability"
        }

        /// The arrays zipped to the shortest of them: an entry needs a time
        /// and a temperature to be a bar, and a series whose arrays disagree
        /// is read only as far as all of them reach. A probability array
        /// missing altogether leaves every hour's probability unknown rather
        /// than cutting the series to nothing.
        var points: [WeatherReading.HourlyPoint] {
            guard let time, let temperature else { return [] }
            var count = min(time.count, temperature.count)
            if let precipitationProbability { count = min(count, precipitationProbability.count) }
            return (0..<count).map { index in
                WeatherReading.HourlyPoint(
                    time: Date(timeIntervalSince1970: time[index]),
                    temperature: temperature[index],
                    precipitationProbability: precipitationProbability?[index]
                )
            }
        }
    }

    struct Daily: Decodable {
        let temperatureMax: [Double?]?
        let temperatureMin: [Double?]?
        let sunrise: [Double]?
        let sunset: [Double]?

        private enum CodingKeys: String, CodingKey {
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case sunrise, sunset
        }
    }

    struct Current: Decodable {
        let code: Int
        let isDay: Int
        let temperature: Double
        /// Optional for the same reason `interval` is, and by the same
        /// mechanism: an optional property is decoded with `decodeIfPresent`,
        /// so a `current` object that stops carrying the field is still a
        /// reading rather than a failed poll.
        let apparentTemperature: Double?
        let precipitation: Double
        let windSpeed: Double
        let relativeHumidity: Double?
        let windDirection: Double?
        let windGusts: Double?
        let uvIndex: Double?
        /// Optional so a response that stops carrying it reads as "use the
        /// floor" rather than as a malformed answer — the cadence is a courtesy
        /// of the service, not a reading.
        let interval: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case interval
            case code = "weather_code"
            case isDay = "is_day"
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity = "relative_humidity_2m"
            case precipitation
            case windSpeed = "wind_speed_10m"
            case windDirection = "wind_direction_10m"
            case windGusts = "wind_gusts_10m"
            case uvIndex = "uv_index"
        }
    }

    var reading: WeatherReading {
        WeatherReading(
            code: current.code,
            isDay: current.isDay != 0,
            temperature: current.temperature,
            apparentTemperature: current.apparentTemperature,
            precipitation: current.precipitation,
            windSpeed: current.windSpeed,
            interval: current.interval ?? OpenMeteoSource.defaultInterval,
            relativeHumidity: current.relativeHumidity,
            windDirection: current.windDirection,
            windGusts: current.windGusts,
            uvIndex: current.uvIndex,
            // Index 0 is today: `timezone=auto` makes the first daily bucket
            // the place's current local day.
            todayHigh: daily?.temperatureMax?.first ?? nil,
            todayLow: daily?.temperatureMin?.first ?? nil,
            sunrises: (daily?.sunrise ?? []).map { Date(timeIntervalSince1970: $0) },
            sunsets: (daily?.sunset ?? []).map { Date(timeIntervalSince1970: $0) },
            hourly: hourly?.points ?? []
        )
    }
}
