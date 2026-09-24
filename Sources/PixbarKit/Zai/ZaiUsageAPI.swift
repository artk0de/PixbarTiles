// Sources/PixbarKit/Zai/ZaiUsageAPI.swift
import Foundation

/// Where a z.ai reading comes from.
///
/// A protocol rather than the API itself, so the faces can be tested against a
/// reading and the connector never reaches the network — the seam the Claude
/// connector's reporter is.
public protocol ZaiUsageReporting: Sendable {
    /// The current reading, or nil when there is none to be had: no key
    /// pasted yet, and nothing to ask with.
    func read() async throws -> ZaiUsageReading?
}

/// The two dashboard routes, asked beside each other.
///
/// z.ai documents no usage API. These are the routes the web console itself
/// calls, as the community trackers found them, and they carry no stability
/// contract — which is why every request is one GET with the key pasted raw
/// (no `Bearer`: the dashboard's own XHR sends it bare, and a scheme prefix
/// would authenticate as nobody), every answer goes through the tolerant
/// decoder, and only the READING route's death can fail a read. The limits
/// ride beside it: a dead quota route empties the windows and nothing else.
public struct ZaiUsageAPI: ZaiUsageReporting {
    /// Which platform the plan was bought on. Same routes, different host.
    public enum Host: Sendable {
        case zai
        /// A Zhipu plan.
        case zhipu

        var baseURL: URL {
            switch self {
            case .zai: URL(string: "https://api.z.ai")!
            case .zhipu: URL(string: "https://open.bigmodel.cn")!
            }
        }
    }

    /// The window the model-usage answer reports: the trailing seven days,
    /// the span the community tracker asks for by default.
    public static let windowLength = 7 * 86_400.0

    /// The wall-clock shape the dashboard's own queries spell their bounds in.
    /// Seconds resolution, local time — a server reading local wall time
    /// cannot be handed an offset it did not ask for.
    public static let dateFormat = "yyyy-MM-dd HH:mm:ss"

    /// The window a model-usage query names: seven days back from midnight,
    /// through now.
    public static func window(now: Date) -> (start: Date, end: Date) {
        (
            Calendar.current.startOfDay(for: now).addingTimeInterval(-windowLength),
            now
        )
    }

    /// The one route whose death is a failed read.
    public static let readingPath = "/api/monitor/usage/model-usage"
    /// The route the limits ride beside the reading on.
    public static let limitsPath = "/api/monitor/usage/quota/limit"

    public enum Failure: Error, Sendable, Equatable {
        /// A route answered, and the answer was no. The path and the status
        /// are what failing says — the routes have no body contract to quote.
        case route(String, Int)
    }

    private let transport: any Transport
    private let host: Host
    /// Read on every read rather than held, for the same reason the weather's
    /// location is: a key pasted into the detail takes effect at the next
    /// poll, not at the next launch.
    private let key: @Sendable () -> String?
    private let now: @Sendable () -> Date

    public init(
        transport: any Transport, host: Host = .zai,
        key: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.host = host
        self.key = key
        self.now = now
    }

    public func read() async throws -> ZaiUsageReading? {
        // No key, no reading, no traffic: there is nothing to ask with, and
        // the tile has no figure until somebody pastes one in.
        guard let key = key(), !key.isEmpty else { return nil }

        let totals = try await fetchTotals(key: key)
        // Beside the reading, and it stays there: whatever happens to the
        // quota route costs the windows and nothing else.
        let limits = try? await fetchLimits(key: key)

        return ZaiUsageReading(limits: limits ?? ZaiUsageLimits(), totals: totals, observedAt: now())
    }

    // MARK: - The routes

    private func fetchTotals(key: String) async throws -> ZaiUsageTotals {
        let data = try await ask(
            path: Self.readingPath,
            query: { window in
                [
                    "endTime": Self.formatted(window.end),
                    "startTime": Self.formatted(window.start),
                ]
            },
            key: key
        )
        return ZaiUsageDecoder.totals(from: data)
    }

    private func fetchLimits(key: String) async throws -> ZaiUsageLimits {
        let data = try await ask(path: Self.limitsPath, query: { _ in [:] }, key: key)
        return ZaiUsageDecoder.limits(from: data)
    }

    /// One route, asked once: a GET with the key riding raw in the
    /// Authorization header — the dashboard's own XHR carries it with no
    /// `Bearer` scheme, and a prefix would authenticate as nobody — plus,
    /// when the route takes them, the query bounds spelled the way the
    /// dashboard spells them.
    private func ask(
        path: String, query: ((start: Date, end: Date)) -> [String: String],
        key: String
    ) async throws -> Data {
        var components = URLComponents(
            url: host.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )
        let items = query(Self.window(now: now()))
            .sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else {
            throw Failure.route(path, -1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.route(response.url?.path ?? path, response.statusCode)
        }
        return data
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
