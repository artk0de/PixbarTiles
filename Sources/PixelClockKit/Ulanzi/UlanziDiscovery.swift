import Darwin
import Foundation

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
/// the address mapping above it carry all of the logic — the mapping is pure
/// and tested, the socket is not.
///
/// A BSD datagram socket, deliberately not `NWListener`: it is call for call
/// the shape that demonstrably receives the clock's broadcasts on this
/// machine — a `0.0.0.0` bind with `recvfrom` — with no framework layer
/// between the kernel and the parser. The `NWListener` phase-3 shape never
/// heard the device from this environment, but that observation is confounded
/// by the macOS application firewall, which silently drops inbound datagrams
/// for binaries it has not been asked about; only the shipped app, allowed
/// like any other, settles which shape the firewall was hiding.
public final class UlanziBroadcastListener: Sendable {
    /// How long one `recvfrom` waits before the loop checks whether the
    /// stream was cancelled. Short enough that stopping is prompt, long
    /// enough that a one-a-second broadcast costs almost nothing.
    static let pollInterval: TimeInterval = 0.5

    private let port: UInt16

    public init(port: UInt16 = 55_555) {
        self.port = port
    }

    /// The address a datagram arrived from, as the app talks to hosts.
    ///
    /// Nil for an address that cannot be rendered — a sighting without an
    /// address cannot become a record "Add" could act on, so the receiver
    /// drops it.
    static func host(of address: sockaddr_in) -> String? {
        var address = address
        guard address.sin_family == sa_family_t(AF_INET) else { return nil }
        var rendered = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = withUnsafePointer(to: &address.sin_addr) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<in_addr>.size) {
                inet_ntop(AF_INET, $0, &rendered, socklen_t(INET_ADDRSTRLEN))
            }
        }
        guard result != nil else { return nil }
        let bytes = rendered.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Binds the datagram socket, or nil when it cannot — the port taken by a
    /// second listener in the same process, most likely.
    private static func makeSocket(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: suseconds_t(pollInterval * 1_000_000))
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public func announcements() -> AsyncStream<UlanziSighting> {
        AsyncStream { continuation in
            guard let fd = Self.makeSocket(port: port) else {
                // The port is taken. Yield nothing rather than half-listen.
                continuation.finish()
                return
            }

            let stopped = Stopped()
            continuation.onTermination = { _ in
                stopped.stop()
                close(fd)
            }

            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 2048)
                let capacity = buffer.count
                while !stopped.isStopped {
                    var source = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let received = withUnsafeMutableBytes(of: &buffer) { bytes in
                        withUnsafeMutablePointer(to: &source) { address in
                            address.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                                recvfrom(
                                    fd, bytes.baseAddress, capacity, 0,
                                    address, &length
                                )
                            }
                        }
                    }
                    guard received > 0,
                        let line = String(
                            bytes: buffer[0..<received], encoding: .utf8
                        ),
                        let announcement = UlanziAnnouncement.parse(line),
                        let host = Self.host(of: source)
                    else { continue }
                    continuation.yield(
                        UlanziSighting(announcement: announcement, host: host)
                    )
                }
            }
        }
    }

    /// The loop's exit flag. A `close` does not reliably wake a `recvfrom`
    /// blocked on the same file descriptor, so the receiver polls this on
    /// every timeout instead of trusting the close to interrupt it.
    private final class Stopped: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func stop() { lock.withLock { value = true } }
        var isStopped: Bool { lock.withLock { value } }
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
