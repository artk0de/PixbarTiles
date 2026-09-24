import Foundation
import Testing
@testable import PixbarKit

/// A fully scripted byte stream: hands back canned device bytes on read, and
/// records everything the client writes so the frames can be asserted.
private actor ScriptedStream: ADBStream {
    private var toRead: Data
    private var written = Data()
    init(_ canned: Data) { self.toRead = canned }
    func write(_ bytes: Data) async throws { written.append(bytes) }
    func readExactly(_ count: Int) async throws -> Data {
        guard toRead.count >= count else { throw ADBError.remoteClosed }
        let head = toRead.prefix(count)
        toRead.removeFirst(count)
        return Data(head)
    }
    func close() async {}
    func writtenBytes() -> Data { written }
}

/// Builds one ADB frame the way the device would: 24-byte header
/// (cmd, arg0, arg1, len, payload-checksum, cmd^0xFFFFFFFF) + payload.
private func frame(_ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ payload: Data = Data()) -> Data {
    var d = Data()
    func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(Data($0)) } }
    let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    le(cmd); le(a0); le(a1); le(UInt32(payload.count)); le(checksum); le(cmd ^ 0xFFFF_FFFF)
    d.append(payload)
    return d
}

private let A_CNXN: UInt32 = 0x4E58_4E43
private let A_OKAY: UInt32 = 0x5941_4B4F
private let A_WRTE: UInt32 = 0x4554_5257
private let A_CLSE: UInt32 = 0x4553_4C43

/// The stream id the client's FIRST operation opens. Ids are monotonic and
/// never reused, so the device addresses its answers to this one — the device's
/// frames carry it in arg1, and the client only reads frames that match.
private let firstStream: UInt32 = 2

private func le32(_ v: UInt32) -> Data {
    withUnsafeBytes(of: v.littleEndian) { Data($0) }
}

/// The CNXN the device answers the handshake with.
private let handshake = frame(A_CNXN, 0x0100_0000, 256 * 1024, Data("device::\0".utf8))

@Test func shellCollectsWriteFramesUntilClose() async throws {
    var canned = handshake
    canned += frame(A_WRTE, 9, firstStream, Data("Battery: ".utf8))
    canned += frame(A_WRTE, 9, firstStream, Data("90%\n".utf8))
    canned += frame(A_CLSE, 9, firstStream)
    let stream = ScriptedStream(canned)
    let client = ADBClient(connect: { stream })

    let out = try await client.shell("echo hi")

    #expect(String(decoding: out, as: UTF8.self) == "Battery: 90%\n")
    // The client must have opened the shell service by name.
    let written = await stream.writtenBytes()
    #expect(written.range(of: Data("shell:echo hi\0".utf8)) != nil)
    // And sent a CNXN first (the handshake precedes the OPEN).
    #expect(written.prefix(4) == withUnsafeBytes(of: A_CNXN.littleEndian) { Data($0) })
}

@Test func pullReassemblesSyncDataChunksByteExactly() async throws {
    // The battery window contains a 0x0a byte, which the shell PTY would turn
    // into 0x0d 0x0a. sync RECV must hand it back untouched.
    let window = Data([1, 0, 0, 0, 10, 0, 0, 0, 0x0A, 0x0C, 0, 0])
    var sync = Data("DATA".utf8) + le32(UInt32(window.count)) + window
    sync += Data("DONE".utf8) + le32(0)

    var canned = handshake
    canned += frame(A_OKAY, 9, firstStream)                   // sync: opened
    canned += frame(A_WRTE, 9, firstStream, sync)
    canned += frame(A_CLSE, 9, firstStream)
    let stream = ScriptedStream(canned)
    let client = ADBClient(connect: { stream })

    let out = try await client.pull("/tmp/pbt-out")

    #expect(out == window)
    let written = await stream.writtenBytes()
    #expect(written.range(of: Data("RECV".utf8)) != nil)
    #expect(written.range(of: Data("/tmp/pbt-out".utf8)) != nil)
}

@Test func framesLeftOverFromAFinishedStreamAreNotReadAsThisOnes() async throws {
    // The device's CLSE for the PREVIOUS operation arrives late, after that
    // operation stopped reading. Measured against the clock, a client that
    // took it at face value ended the next operation before it began: a shell
    // straight after a push answered nothing at all.
    var canned = handshake
    canned += frame(A_CLSE, 7, firstStream - 1)               // the last stream's
    canned += frame(A_OKAY, 7, firstStream - 1)               // and its stray ack
    canned += frame(A_WRTE, 9, firstStream, Data("real".utf8))
    canned += frame(A_CLSE, 9, firstStream)
    let stream = ScriptedStream(canned)
    let client = ADBClient(connect: { stream })

    let out = try await client.shell("echo real")

    #expect(String(decoding: out, as: UTF8.self) == "real")
}

@Test func oneConnectionCarriesSeveralOperations() async throws {
    // The handshake happens ONCE; each operation opens a new stream id on the
    // same socket. Driving a connection per operation exhausted this adbd.
    var canned = handshake
    canned += frame(A_WRTE, 9, firstStream, Data("one".utf8))
    canned += frame(A_CLSE, 9, firstStream)
    canned += frame(A_WRTE, 9, firstStream + 1, Data("two".utf8))
    canned += frame(A_CLSE, 9, firstStream + 1)
    let stream = ScriptedStream(canned)
    let client = ADBClient(connect: { stream })

    let first = try await client.shell("echo one")
    let second = try await client.shell("echo two")

    #expect(String(decoding: first, as: UTF8.self) == "one")
    #expect(String(decoding: second, as: UTF8.self) == "two")
    // Exactly one CNXN went out, however many operations ran.
    let written = await stream.writtenBytes()
    let cnxnCount = written.ranges(of: le32(A_CNXN)).count
    #expect(cnxnCount == 1)
}

extension Data {
    /// Every range at which `pattern` occurs — used to count handshakes.
    fileprivate func ranges(of pattern: Data) -> [Range<Index>] {
        var found: [Range<Index>] = []
        var searchFrom = startIndex
        while let r = self[searchFrom...].range(of: pattern) {
            found.append(r)
            searchFrom = r.upperBound
            if searchFrom >= endIndex { break }
        }
        return found
    }
}
