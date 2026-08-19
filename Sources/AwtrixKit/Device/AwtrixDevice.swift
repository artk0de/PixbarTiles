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

/// One app in the device's own loop.
///
/// Fewer fields than a notification, and that is the difference between the two
/// rather than an omission: `hold`, `stack`, `wakeup` and the repeat count are
/// all about interrupting, and an app in the loop interrupts nothing.
public struct AppPayload: Sendable, Equatable {
    public var text: String
    public var icon: String?
    public var color: String?
    /// How long the loop rests on this app. Left unset, the device uses its own
    /// app time — which the user chose in its settings, and which this app has
    /// no better answer than.
    public var duration: Int?
    /// Seconds without an update after which the clock removes this app by
    /// itself, or nil to leave it in the loop until this app takes it out.
    ///
    /// The only ending that removes an app is a clean quit, and the endings
    /// that matter are the other ones: a crash, a force quit, the Mac sleeping,
    /// the network dropping. Every one of them leaves the last reading on the
    /// matrix for good — yesterday's temperature shown as today's, with nothing
    /// on screen to say it is stale.
    ///
    /// Deletion rather than the firmware's `lifetimeMode: 1`, which keeps the
    /// app and draws a red rectangle round it. A marked-stale app is still a
    /// number in the rotation, and a red border says "this app has a problem"
    /// to somebody who has never read this file; an app that is simply gone
    /// says the one true thing, that nothing here knows the temperature any
    /// more. The default mode is the deleting one, so nothing is sent for it.
    ///
    /// A consequence worth knowing before it surprises somebody: `pos` — where
    /// the app sits in the loop — applies only on the FIRST push of a name. An
    /// app the clock removed on its lifetime and this app later pushes again is
    /// a first push, so it can come back in a different place in the rotation
    /// than it left.
    public var lifetime: Int?
    /// The colour of the panel behind the text, or nil to leave it unlit.
    ///
    /// Six hex digits behind a hash, the only form the firmware parses — the
    /// same silence `color` is written against, and it costs more here: a
    /// background it drops leaves the panel dark, which is exactly what "no
    /// background" looks like. A malformed one is therefore not a wrong colour
    /// but an invisible one.
    ///
    /// nil rather than black, and they are not the same instruction. Black is a
    /// colour the firmware is told to paint over 256 pixels; nil is the key
    /// left out, which is what every other app in the loop sends and what the
    /// device does by default.
    public var background: String?

    public init(
        text: String,
        icon: String? = nil,
        color: String? = nil,
        duration: Int? = nil,
        lifetime: Int? = nil,
        background: String? = nil
    ) {
        self.text = text
        self.icon = icon
        self.color = color
        self.duration = duration
        self.lifetime = lifetime
        self.background = background
    }

    /// Only set fields are emitted — the firmware rejects nulls.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["text": text]
        if let icon { object["icon"] = icon }
        if let color { object["color"] = color }
        if let duration { object["duration"] = duration }
        if let lifetime { object["lifetime"] = lifetime }
        if let background { object["background"] = background }
        return object
    }
}

/// The clock's own settings, of which this app reads exactly one.
public struct DeviceSettings: Sendable, Equatable {
    /// The device-wide weather layer.
    ///
    /// The raw string the device answered with, not a `DeviceOverlay`. A
    /// firmware that knows a name this app does not must be handed back exactly
    /// what it had — decoding it into the six this app understands would put
    /// `clear` back over a setting the user chose.
    ///
    /// Optional because a firmware without the key at all is not a failure to
    /// read: there is simply nothing there to put back.
    public let overlay: String?

    public init(overlay: String?) {
        self.overlay = overlay
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

    /// Normalised here as well as at the field the user types into, because
    /// the field is not the only writer: `AppModel`'s own documentation tells
    /// the reader to point the app at a different clock with
    /// `defaults write dev.artk0re.awtrix-connectors deviceHost`, and whatever
    /// they put there arrives at this initialiser untouched.
    ///
    /// A value nothing can be made of is kept exactly as it stands, rather than
    /// replaced with something plausible: `perform` then reports it by name
    /// through `AwtrixError.invalidHost`, which is the one message that says
    /// what is actually wrong.
    public init(host: String, transport: Transport) {
        self.host = DeviceAddress.host(from: host) ?? host
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

    /// Puts an app in the device's own loop, or replaces the one already there
    /// under this name.
    public func showApp(_ payload: AppPayload, named name: String) async throws {
        _ = try await postJSON("/api/custom?name=\(name)", payload.jsonObject)
    }

    /// Takes an app back out of the loop. An empty body is how the firmware is
    /// told to forget one.
    public func removeApp(named name: String) async throws {
        _ = try await perform(
            "POST", "/api/custom?name=\(name)", body: Data(), contentType: "application/json"
        )
    }

    // MARK: settings

    /// The clock's settings, of which this app reads the overlay.
    ///
    /// Read through `JSONSerialization` rather than a `Decodable` of one field,
    /// because the response is the device's whole settings object — three dozen
    /// keys whose types are the firmware's business — and a struct naming one
    /// of them would still have to be tolerant of every other.
    public func settings() async throws -> DeviceSettings {
        let data = try await perform("GET", "/api/settings")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return DeviceSettings(overlay: object?["OVERLAY"] as? String)
    }

    /// Sets the device-wide weather layer.
    ///
    /// Takes the name rather than a `DeviceOverlay`, because putting back what
    /// was there before means writing whatever the device had — including a
    /// name this app does not know. Everything this app CHOOSES to write comes
    /// from `DeviceOverlay`, which is the validation the firmware does not do:
    /// it accepts any string, answers 200, and silently shows `clear`.
    public func setOverlay(named overlay: String) async throws {
        _ = try await postJSON("/api/settings", ["OVERLAY": overlay])
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
