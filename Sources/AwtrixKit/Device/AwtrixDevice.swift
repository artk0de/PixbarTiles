import Foundation

/// One device's HTTP surface. Field names below are the firmware's, not Swift's.
public struct NotifyPayload: Sendable {
    public var text: String
    public var icon: String?
    public var duration: Int?
    public var color: String?
    public var rtttl: String?
    public var sound: String?
    public var repeatCount: Int?
    public var scrollSpeed: Int?
    public var stack: Bool?
    public var wakeup: Bool?
    public var hold: Bool?
    public var pushIcon: Int?

    public init(
        text: String,
        icon: String? = nil,
        duration: Int? = nil,
        color: String? = nil,
        rtttl: String? = nil,
        sound: String? = nil,
        repeatCount: Int? = nil,
        scrollSpeed: Int? = nil,
        stack: Bool? = nil,
        wakeup: Bool? = nil,
        hold: Bool? = nil,
        pushIcon: Int? = nil
    ) {
        self.text = text
        self.icon = icon
        self.duration = duration
        self.color = color
        self.rtttl = rtttl
        self.sound = sound
        self.repeatCount = repeatCount
        self.scrollSpeed = scrollSpeed
        self.stack = stack
        self.wakeup = wakeup
        self.hold = hold
        self.pushIcon = pushIcon
    }

    /// Only set fields are emitted — the firmware rejects nulls.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["text": text]
        if let icon { object["icon"] = icon }
        if let duration { object["duration"] = duration }
        if let color { object["color"] = color }
        if let rtttl { object["rtttl"] = rtttl }
        if let sound { object["sound"] = sound }
        if let repeatCount { object["repeat"] = repeatCount }
        if let scrollSpeed { object["scrollSpeed"] = scrollSpeed }
        if let stack { object["stack"] = stack }
        if let wakeup { object["wakeup"] = wakeup }
        if let hold { object["hold"] = hold }
        if let pushIcon { object["pushIcon"] = pushIcon }
        return object
    }
}

public struct DeviceStats: Sendable, Decodable, Equatable {
    public let version: String
    public let uid: String
    public let bat: Int
    /// The reading `bat` is derived from, and the finer of the two: 648 where
    /// `bat` says 91. Percent is what the user reads; this is what a trend is
    /// computed on, because an integer percentage only moves every seventh
    /// reading and a poll every twenty seconds would spend two minutes with
    /// nothing to say.
    ///
    /// Optional because a firmware that does not report it must not read as an
    /// unreachable clock. `DeviceStats` failing to decode is what puts the
    /// monitor offline, and a missing trend field is not a missing device — the
    /// panel shows the percentage and no verdict, which is the state the
    /// trajectory already has a name for.
    public let batRaw: Int?
    /// Seconds since the device booted. Optional for the reason `batRaw` is.
    ///
    /// Read for one purpose: it going backwards is a reboot, and a reboot is
    /// exactly when somebody unplugged the clock and plugged it in again. The
    /// readings either side of it describe two different situations.
    public let uptime: Int?
    public let ram: Int
    public let ipAddress: String

    private enum CodingKeys: String, CodingKey {
        case version, uid, bat, ram, uptime
        case batRaw = "bat_raw"
        case ipAddress = "ip_address"
    }

    /// Spelled out rather than synthesized, so the two optional fields can carry
    /// defaults: every caller that predates them names the five it always named.
    public init(
        version: String,
        uid: String,
        bat: Int,
        batRaw: Int? = nil,
        uptime: Int? = nil,
        ram: Int,
        ipAddress: String
    ) {
        self.version = version
        self.uid = uid
        self.bat = bat
        self.batRaw = batRaw
        self.uptime = uptime
        self.ram = ram
        self.ipAddress = ipAddress
    }
}

public actor AwtrixDevice {
    private let host: String
    private let transport: Transport

    public init(host: String, transport: Transport) {
        self.host = host
        self.transport = transport
    }

    // MARK: sending

    public func notify(_ payload: NotifyPayload) async throws {
        _ = try await postJSON("/api/notify", payload.jsonObject)
    }

    public func dismissNotification() async throws {
        _ = try await postJSON("/api/notify/dismiss", [:])
    }

    public func playRTTTL(_ melody: String) async throws {
        _ = try await perform("POST", "/api/rtttl", body: Data(melody.utf8), contentType: "text/plain")
    }

    public func playMelody(named name: String) async throws {
        _ = try await postJSON("/api/sound", ["sound": name])
    }

    public func stats() async throws -> DeviceStats {
        let data = try await perform("GET", "/api/stats")
        return try JSONDecoder().decode(DeviceStats.self, from: data)
    }

    // MARK: transport plumbing

    func postJSON(_ path: String, _ object: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await perform("POST", path, body: body, contentType: "application/json")
    }

    func perform(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw AwtrixError.invalidHost(host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AwtrixError.http(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self),
                endpoint: path
            )
        }
        return data
    }
}
