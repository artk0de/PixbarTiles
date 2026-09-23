import Foundation
import Testing
@testable import PixelClockKit

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

private func le32(_ v: UInt32) -> Data {
    withUnsafeBytes(of: v.littleEndian) { Data($0) }
}

@Test func shellCollectsWriteFramesUntilClose() async throws {
    // Device answers: CNXN (handshake), then two WRTE chunks, then CLSE.
    var canned = frame(A_CNXN, 0x0100_0000, 256 * 1024, Data("device::\0".utf8))
    canned += frame(A_WRTE, 1, 1, Data("Battery: ".utf8))
    canned += frame(A_WRTE, 1, 1, Data("90%\n".utf8))
    canned += frame(A_CLSE, 1, 1)
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

    var canned = frame(A_CNXN, 0x0100_0000, 256 * 1024, Data("device::\0".utf8))
    canned += frame(A_OKAY, 7, 1)                       // sync: opened
    canned += frame(A_WRTE, 7, 1, sync)
    canned += frame(A_CLSE, 7, 1)
    let stream = ScriptedStream(canned)
    let client = ADBClient(connect: { stream })

    let out = try await client.pull("/tmp/pct-out")

    #expect(out == window)
    let written = await stream.writtenBytes()
    #expect(written.range(of: Data("RECV".utf8)) != nil)
    #expect(written.range(of: Data("/tmp/pct-out".utf8)) != nil)
}
