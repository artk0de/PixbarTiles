import Foundation
import Network

/// One UDP 55555 broadcast line, parsed (research A1). The devices shout
/// roughly one line per second:
///
///     Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false
///
/// The trailing flag is carried raw — its meaning is unverified (appendix A1),
/// and a raw string keeps a guess out of the model.
public struct UlanziAnnouncement: Equatable, Sendable {
    public let model: String
    public let mac: String
    public let serial: String
    /// Trailing field, carried raw — its meaning is unverified (appendix A1).
    public let flag: String

    public static func parse(_ line: String) -> UlanziAnnouncement? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count == 3, words[0] == "Ulanzi" else { return nil }
        let parts = words[2].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        return UlanziAnnouncement(
            model: String(words[1]),
            mac: String(parts[1]),
            serial: String(parts[2]),
            flag: String(parts[3])
        )
    }
}

/// An announcement together with the address it arrived from. The broadcast
/// line carries no address, and the datagram's source is the device's own —
/// the pair is what lets a sighting become a clock record with somewhere to
/// talk to.
public struct UlanziSighting: Sendable, Equatable {
    public let announcement: UlanziAnnouncement
    /// The host the broadcast was sent from, already bare — no port, no brackets.
    public let host: String

    public init(announcement: UlanziAnnouncement, host: String) {
        self.announcement = announcement
        self.host = host
    }
}

/// Passive UDP 55555 listener yielding sightings. Untested by
/// design (D13): the socket is the only untested surface, and the parser and
/// the endpoint mapping above it carry all of the logic — the mapping is pure
/// and tested, the socket is not.
public final class UlanziBroadcastListener: Sendable {
    private let port: UInt16

    public init(port: UInt16 = 55_555) {
        self.port = port
    }

    /// The address a datagram arrived from, as the app talks to hosts.
    ///
    /// Nil for an endpoint that names no address — a service announcement is
    /// somebody else's way of speaking, and a sighting without an address
    /// cannot become a record "Add" could act on, so the caller drops it.
    static func host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4, .ipv6, .name:
            return String(describing: host)
        default:
            return nil
        }
    }

    public func announcements() -> AsyncStream<UlanziSighting> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "dev.artk0re.pixelclocktiles.ulanzi-broadcast")
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            guard let endpoint = NWEndpoint.Port(rawValue: port),
                let listener = try? NWListener(using: parameters, on: endpoint)
            else {
                // The port is taken — a second listener in the same process,
                // most likely. Yield nothing rather than half-listen.
                continuation.finish()
                return
            }

            listener.newConnectionHandler = { connection in
                let host = Self.host(of: connection.endpoint)
                connection.receiveMessage { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data,
                        let line = String(data: data, encoding: .utf8),
                        let announcement = UlanziAnnouncement.parse(line),
                        let host
                    else { return }
                    continuation.yield(UlanziSighting(announcement: announcement, host: host))
                }
                connection.start(queue: queue)
            }
            listener.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in listener.cancel() }
            listener.start(queue: queue)
        }
    }
}

/// Model detection: probe both endpoints concurrently, whichever body DECODES
/// wins (research A2 — statuses never decide, because this firmware answers
/// the AWTRIX stats path with a redirect). When both decode — degenerate —
/// `ulanzi` wins deterministically. Phase 4 owns the first caller.
public enum UlanziProbe {
    public enum Detection: Equatable, Sendable {
        case ulanzi(UlanziIdentity)
        case otherDevice
        case undetermined
    }

    public static func detect(host: String, transport: any Transport) async -> Detection {
        let ulanzi = UlanziDevice(host: host, transport: transport)
        let awtrix = AwtrixDevice(host: host, transport: transport)
        // The AWTRIX half reuses `AwtrixDevice.stats()`'s own decode rather
        // than redefining the AWTRIX body shape here.
        async let base = try? ulanzi.identity()
        async let stats = try? awtrix.stats()
        let (identity, deviceStats) = await (base, stats)
        if let identity { return .ulanzi(identity) }
        if deviceStats != nil { return .otherDevice }
        return .undetermined
    }
}
