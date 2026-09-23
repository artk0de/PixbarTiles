import Foundation
import Network

/// The byte-level seam `ADBClient` frames over. A fake in tests, a real TCP
/// socket (`NWADBStream`) in the app — so the wire framing is a pure function
/// of the stream and never touches a device under test.
public protocol ADBStream: Sendable {
    func write(_ bytes: Data) async throws
    /// Reads exactly `count` bytes, or throws `ADBError.remoteClosed` if the
    /// stream ends first.
    func readExactly(_ count: Int) async throws -> Data
    func close() async
}

/// The two operations the battery read needs from ADB. `ADBClient` conforms;
/// a fake conforms in `UlanziBattery`'s tests.
public protocol ADB: Sendable {
    func shell(_ command: String) async throws -> Data
    func push(_ bytes: Data, to path: String, mode: Int) async throws
}

public enum ADBError: Error, Equatable {
    case handshakeRefused
    case remoteClosed
    case syncFailed(String)
}

/// A minimal ADB-over-TCP client. One fresh connection per operation: connect,
/// `CNXN` handshake, one service `OPEN`, drive it, close. This is exactly what
/// the spike proved against the TC002's open, AUTH-less adbd, and it keeps the
/// framing a pure function of the byte stream so tests script it.
public struct ADBClient: ADB {
    private static let cnxn: UInt32 = 0x4E58_4E43   // "CNXN"
    private static let open: UInt32 = 0x4E45_504F   // "OPEN"
    private static let okay: UInt32 = 0x5941_4B4F   // "OKAY"
    private static let clse: UInt32 = 0x4553_4C43   // "CLSE"
    private static let wrte: UInt32 = 0x4554_5257   // "WRTE"
    private static let auth: UInt32 = 0x4855_5441   // "AUTH"
    private static let maxData: UInt32 = 256 * 1024

    private let connect: @Sendable () async throws -> ADBStream

    public init(connect: @escaping @Sendable () async throws -> ADBStream) {
        self.connect = connect
    }

    public func shell(_ command: String) async throws -> Data {
        let stream = try await connect()
        defer { Task { await stream.close() } }
        try await handshake(stream)
        try await send(stream, Self.open, 1, 0, Data("shell:\(command)\0".utf8))
        return try await collect(stream)
    }

    public func push(_ bytes: Data, to path: String, mode: Int) async throws {
        let stream = try await connect()
        defer { Task { await stream.close() } }
        try await handshake(stream)
        try await send(stream, Self.open, 1, 0, Data("sync:\0".utf8))
        let (cmd, remoteId, _, _) = try await recv(stream)
        guard cmd == Self.okay else { throw ADBError.syncFailed("sync not acked") }

        var sync = Data()
        let arg = Data("\(path),\(mode)".utf8)
        sync += Data("SEND".utf8) + encode(UInt32(arg.count)) + arg
        for chunk in bytes.chunked(65536) {
            sync += Data("DATA".utf8) + encode(UInt32(chunk.count)) + chunk
        }
        sync += Data("DONE".utf8) + encode(UInt32(Date().timeIntervalSince1970))
        try await send(stream, Self.wrte, 1, remoteId, sync)

        // The sync-layer response arrives as a WRTE frame: "OKAY" or "FAIL".
        var status = Data()
        while status.count < 8 {
            let (c, _, _, payload) = try await recv(stream)
            if c == Self.wrte {
                status += payload
                try await send(stream, Self.okay, 1, remoteId)
            } else if c == Self.clse {
                break
            }
        }
        guard status.prefix(4) == Data("OKAY".utf8) else {
            throw ADBError.syncFailed(String(decoding: status, as: UTF8.self))
        }
    }

    // MARK: framing

    private func handshake(_ stream: ADBStream) async throws {
        try await send(stream, Self.cnxn, 0x0100_0000, Self.maxData, Data("host::\0".utf8))
        let (cmd, _, _, _) = try await recv(stream)
        if cmd == Self.auth { throw ADBError.handshakeRefused }
        guard cmd == Self.cnxn else { throw ADBError.handshakeRefused }
    }

    /// Collects WRTE payloads until CLSE, acking each with the adb-layer OKAY.
    private func collect(_ stream: ADBStream) async throws -> Data {
        var out = Data()
        while true {
            let (cmd, arg0, _, payload) = try await recv(stream)
            if cmd == Self.wrte {
                out += payload
                try await send(stream, Self.okay, 1, arg0)
            } else if cmd == Self.clse {
                return out
            }
        }
    }

    private func send(
        _ stream: ADBStream, _ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ payload: Data = Data()
    ) async throws {
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        var header = encode(cmd) + encode(a0) + encode(a1)
        header += encode(UInt32(payload.count)) + encode(checksum) + encode(cmd ^ 0xFFFF_FFFF)
        try await stream.write(header + payload)
    }

    private func recv(_ stream: ADBStream) async throws -> (UInt32, UInt32, UInt32, Data) {
        let header = try await stream.readExactly(24)
        let cmd = decode(header, 0)
        let a0 = decode(header, 4)
        let a1 = decode(header, 8)
        let length = Int(decode(header, 12))
        let payload = length > 0 ? try await stream.readExactly(length) : Data()
        return (cmd, a0, a1, payload)
    }

    private func encode(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private func decode(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8)
            | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }
}

extension Data {
    fileprivate func chunked(_ size: Int) -> [Data] {
        stride(from: startIndex, to: endIndex, by: size).map {
            Data(self[$0 ..< Swift.min($0 + size, endIndex)])
        }
    }
}

/// The real byte stream: a TCP connection with a receive buffer so
/// `readExactly` can serve arbitrary lengths from NWConnection's chunked
/// deliveries. Not unit-tested — validated on-device end to end.
public actor NWADBStream: ADBStream {
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    public static func connect(host: String, port: UInt16 = 5555) async throws -> NWADBStream {
        let stream = NWADBStream(host: host, port: port)
        try await stream.start()
        return stream
    }

    private init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let error): cont.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    public func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            if closed { throw ADBError.remoteClosed }
            let chunk = try await receiveChunk()
            if chunk.isEmpty { closed = true } else { buffer.append(chunk) }
        }
        let head = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(head)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
                data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: Data()) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    public func close() async { connection.cancel() }
}
