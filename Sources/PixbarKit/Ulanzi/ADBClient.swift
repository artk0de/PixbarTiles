import Foundation
import Network
import os

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
    /// Reads a file off the device byte-exactly. `shell:` is a PTY and turns
    /// every `0x0a` into `0x0d 0x0a`, so binary never travels over it — the
    /// reader redirects to a file and it comes back through here.
    func pull(_ path: String) async throws -> Data
}

public enum ADBError: Error, Equatable {
    case handshakeRefused
    case remoteClosed
    case syncFailed(String)
}

/// A minimal ADB-over-TCP client against the TC002's open, AUTH-less adbd.
///
/// One connection, handshaken once and kept, with a new stream id per
/// operation — which is how ADB is meant to be driven, and how this device
/// insists on being driven. The framing is a pure function of the byte stream,
/// so tests script it without touching a device.
public actor ADBClient: ADB {
    private static let cnxn: UInt32 = 0x4E58_4E43   // "CNXN"
    private static let open: UInt32 = 0x4E45_504F   // "OPEN"
    private static let okay: UInt32 = 0x5941_4B4F   // "OKAY"
    private static let clse: UInt32 = 0x4553_4C43   // "CLSE"
    private static let wrte: UInt32 = 0x4554_5257   // "WRTE"
    private static let auth: UInt32 = 0x4855_5441   // "AUTH"
    private static let maxData: UInt32 = 256 * 1024

    private let connect: @Sendable () async throws -> ADBStream
    /// The one live connection, kept between operations. ADB multiplexes
    /// streams over a single socket by design, and this device needs it to:
    /// measured against the clock, a connection per operation exhausted adbd
    /// after half a dozen and every later one was met with a reset. One poll
    /// needs six operations, so per-operation connections could not even
    /// complete a second read.
    private var live: ADBStream?
    /// The next stream id to open. Monotonic, never reused, because the device
    /// answers on the id it was opened with.
    private var nextLocalId: UInt32 = 1

    public init(connect: @escaping @Sendable () async throws -> ADBStream) {
        self.connect = connect
    }

    private func liveStream() async throws -> ADBStream {
        if let live { return live }
        let fresh = try await connect()
        try await handshake(fresh)
        live = fresh
        return fresh
    }

    private func drop() async {
        if let live { await live.close() }
        live = nil
    }

    /// Runs one operation on the shared connection, and retries ONCE on a fresh
    /// one. The retry is what makes an idle-closed socket invisible: polls are
    /// minutes apart, and the device is free to hang up in between.
    private func run<T>(_ body: (ADBStream, UInt32) async throws -> T) async throws -> T {
        do {
            let stream = try await liveStream()
            nextLocalId += 1
            return try await body(stream, nextLocalId)
        } catch {
            await drop()
            let stream = try await liveStream()
            nextLocalId += 1
            do {
                return try await body(stream, nextLocalId)
            } catch {
                await drop()
                throw error
            }
        }
    }

    public func shell(_ command: String) async throws -> Data {
        try await run { stream, localId in
            try await send(stream, Self.open, localId, 0, Data("shell:\(command)\0".utf8))
            return try await collect(stream, localId)
        }
    }

    public func push(_ bytes: Data, to path: String, mode: Int) async throws {
        try await run { stream, localId in
            try await pushing(stream, localId, bytes, to: path, mode: mode)
        }
    }

    private func pushing(
        _ stream: ADBStream, _ localId: UInt32, _ bytes: Data, to path: String, mode: Int
    ) async throws {
        try await send(stream, Self.open, localId, 0, Data("sync:\0".utf8))
        let (cmd, remoteId, _, _) = try await recv(stream, for: localId)
        guard cmd == Self.okay else { throw ADBError.syncFailed("sync not acked") }

        var sync = Data()
        let arg = Data("\(path),\(mode)".utf8)
        sync += Data("SEND".utf8) + encode(UInt32(arg.count)) + arg
        for chunk in bytes.chunked(65536) {
            sync += Data("DATA".utf8) + encode(UInt32(chunk.count)) + chunk
        }
        sync += Data("DONE".utf8) + encode(UInt32(Date().timeIntervalSince1970))
        try await send(stream, Self.wrte, localId, remoteId, sync)

        // The sync-layer response arrives as a WRTE frame: "OKAY" or "FAIL".
        var status = Data()
        while status.count < 8 {
            let (c, _, _, payload) = try await recv(stream, for: localId)
            if c == Self.wrte {
                status += payload
                try await send(stream, Self.okay, localId, remoteId)
            } else if c == Self.clse {
                break
            }
        }
        guard status.prefix(4) == Data("OKAY".utf8) else {
            throw ADBError.syncFailed(String(decoding: status, as: UTF8.self))
        }
        await quitSync(stream, localId, remoteId)
    }

    public func pull(_ path: String) async throws -> Data {
        try await run { stream, localId in
            try await pulling(stream, localId, path)
        }
    }

    private func pulling(_ stream: ADBStream, _ localId: UInt32, _ path: String) async throws -> Data {
        try await send(stream, Self.open, localId, 0, Data("sync:\0".utf8))
        let (cmd, remoteId, _, _) = try await recv(stream, for: localId)
        guard cmd == Self.okay else { throw ADBError.syncFailed("sync not acked") }

        let p = Data(path.utf8)
        try await send(stream, Self.wrte, localId, remoteId, Data("RECV".utf8) + encode(UInt32(p.count)) + p)

        // The sync reply is DATA chunks then DONE, and it does not respect WRTE
        // frame boundaries — so it is buffered and parsed incrementally.
        var buffer = Data()
        var out = Data()
        while true {
            while buffer.count >= 8 {
                let tag = Data(buffer.prefix(4))
                let n = Int(decode(buffer, 4))
                if tag == Data("DONE".utf8) {
                    await quitSync(stream, localId, remoteId)
                    return out
                }
                if tag == Data("FAIL".utf8) {
                    guard buffer.count >= 8 + n else { break }
                    let message = Data(buffer.dropFirst(8).prefix(n))
                    throw ADBError.syncFailed(String(decoding: message, as: UTF8.self))
                }
                guard tag == Data("DATA".utf8) else {
                    throw ADBError.syncFailed("unexpected sync tag")
                }
                guard buffer.count >= 8 + n else { break }
                out += Data(buffer.dropFirst(8).prefix(n))
                buffer = Data(buffer.dropFirst(8 + n))
            }
            let (c, _, _, payload) = try await recv(stream, for: localId)
            if c == Self.wrte {
                buffer += payload
                try await send(stream, Self.okay, localId, remoteId)
            } else if c == Self.clse {
                try? await send(stream, Self.clse, localId, remoteId)
                return out
            }
        }
    }

    /// Ends a `sync:` session the way the protocol says to: `QUIT`, then CLSE.
    ///
    /// Not optional politeness. Measured against the clock: with the session
    /// left unterminated, the NEXT connection to this adbd was met with a
    /// connection reset — shell operations chained fine, but anything after a
    /// push or a pull failed. Best-effort, because a failure here must not
    /// lose a read that already succeeded.
    private func quitSync(_ stream: ADBStream, _ localId: UInt32, _ remoteId: UInt32) async {
        try? await send(stream, Self.wrte, localId, remoteId, Data("QUIT".utf8) + encode(0))
        try? await send(stream, Self.clse, localId, remoteId)
    }

    // MARK: framing

    private func handshake(_ stream: ADBStream) async throws {
        try await send(stream, Self.cnxn, 0x0100_0000, Self.maxData, Data("host::\0".utf8))
        let (cmd, _, _, _) = try await recv(stream)
        if cmd == Self.auth { throw ADBError.handshakeRefused }
        guard cmd == Self.cnxn else { throw ADBError.handshakeRefused }
    }

    /// Collects WRTE payloads until CLSE, acking each with the adb-layer OKAY.
    private func collect(_ stream: ADBStream, _ localId: UInt32) async throws -> Data {
        var out = Data()
        while true {
            let (cmd, arg0, _, payload) = try await recv(stream, for: localId)
            if cmd == Self.wrte {
                out += payload
                try await send(stream, Self.okay, localId, arg0)
            } else if cmd == Self.clse {
                // The device closed its end; answer in kind so the stream is
                // fully torn down rather than left half-open.
                try? await send(stream, Self.clse, localId, arg0)
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

    /// The next frame belonging to THIS stream, discarding any that do not.
    ///
    /// One socket carries every stream, and a finished one leaves frames
    /// behind — the device's own CLSE arrives after we have stopped reading.
    /// Without this filter the next operation read that leftover CLSE as its
    /// own and returned empty: measured against the clock, a shell straight
    /// after a push answered nothing at all.
    private func recv(
        _ stream: ADBStream, for localId: UInt32
    ) async throws -> (UInt32, UInt32, UInt32, Data) {
        while true {
            let frame = try await recv(stream)
            if frame.2 == localId { return frame }
        }
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

    /// Connects, or throws — never waits on a refusal.
    ///
    /// `NWConnection` reads a refused or unroutable connect as `.waiting` and
    /// retries by itself, indefinitely; waiting for `.failed` alone held the
    /// caller for good whenever the clock answered HTTP before its adbd was
    /// listening (2026-09-26). A connect that has to wait is a failed one
    /// here: the next poll is the retry.
    private func start() async throws {
        let connection = connection
        let settled = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                let outcome: Result<Void, Error>?
                switch state {
                case .ready: outcome = .success(())
                case .failed(let error), .waiting(let error): outcome = .failure(error)
                case .cancelled: outcome = .failure(ADBError.remoteClosed)
                default: outcome = nil
                }
                guard let outcome, settled.withLock({ done in
                    defer { done = true }
                    return !done
                }) else { return }
                if case .failure = outcome { connection.cancel() }
                cont.resume(with: outcome)
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
