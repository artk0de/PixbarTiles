import Foundation
import Testing
@testable import PixelClockKit

/// A fake ADB that answers scripted shell output by command substring, records
/// pushes, and hands back a canned reader window on pull. No device, no framing.
private actor FakeADB: ADB {
    private let answers: [(match: String, out: Data)]
    private let window: Data
    private var pushed: [(path: String, bytes: Data)] = []

    init(answers: [(String, Data)] = [], window: Data = Data()) {
        self.answers = answers.map { ($0.0, $0.1) }
        self.window = window
    }

    func shell(_ command: String) async throws -> Data {
        for a in answers where command.contains(a.match) { return a.out }
        return Data()
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {
        pushed.append((path, bytes))
    }
    func pull(_ path: String) async throws -> Data { window }
    func pushes() -> [(path: String, bytes: Data)] { pushed }
}

/// 12 reader bytes, little-endian: charging, percent, millivolts.
private func window(charging: UInt32, percent: UInt32, mv: UInt32) -> Data {
    var d = Data()
    for v in [charging, percent, mv] { withUnsafeBytes(of: v.littleEndian) { d.append(Data($0)) } }
    return d
}

/// The real sweep output, as the clock answers it: a /proc/<pid> line, then the
/// NUL-joined cmdline, then a blank line.
private let procList = Data("/proc/1\n/init\u{0}\n\n/proc/670\n/bin/zkgui\u{0}\n\n".utf8)

/// The real maps lines for libzkgui, as read off pid 670.
private let maps = Data("""
43e87000-44571000 r-xp 00000000 1f:03 12         /res/lib/libzkgui.so
44571000-44580000 ---p 006ea000 1f:03 12         /res/lib/libzkgui.so
44580000-445b4000 r--p 006e9000 1f:03 12         /res/lib/libzkgui.so
445b4000-445ba000 rw-p 0071d000 1f:03 12         /res/lib/libzkgui.so
""".utf8)

private func fake(_ w: Data) -> FakeADB {
    FakeADB(answers: [("cmdline", procList), ("maps", maps)], window: w)
}

@Test func readsGatedSampleFromResolvedPidAndBase() async throws {
    let adb = fake(window(charging: 1, percent: 90, mv: 3149))
    let battery = UlanziBattery(adb: adb, helper: Data("ELF-BYTES".utf8))
    let at = Date(timeIntervalSince1970: 1_000)

    let sample = await battery.read(appVersion: "1.1.1", at: at)

    #expect(sample == UlanziBatterySample(percent: 90, charging: true, millivolts: 3149, at: at))
    // base 0x43e87000 + 0x732ee8 = 0x445b9ee8, length 12, pid 670.
    let pushes = await adb.pushes()
    let req = try #require(pushes.first { $0.path == "/tmp/pct-req" }?.bytes)
    #expect(req.prefix(4) == Data([0xE8, 0x9E, 0x5B, 0x44]))
    #expect(req.dropFirst(4).prefix(4) == Data([0x0C, 0x00, 0x00, 0x00]))
    #expect(req.range(of: Data("/proc/670/mem\0".utf8)) != nil)
    // The helper itself is pushed too, since /tmp is wiped on reboot.
    #expect(pushes.contains { $0.path == "/tmp/pct-batt" })
}

@Test func unknownFirmwareYieldsNoReading() async {
    let adb = fake(window(charging: 1, percent: 90, mv: 3149))
    let battery = UlanziBattery(adb: adb, helper: Data())
    #expect(await battery.read(appVersion: "2.0.0", at: Date()) == nil)
    #expect(await battery.read(appVersion: nil, at: Date()) == nil)
}

@Test func implausibleValuesAreRejected() async {
    func read(_ w: Data) async -> UlanziBatterySample? {
        await UlanziBattery(adb: fake(w), helper: Data()).read(appVersion: "1.1.1", at: Date())
    }
    #expect(await read(window(charging: 0, percent: 101, mv: 3000)) == nil)   // percent > 100
    #expect(await read(window(charging: 0, percent: 50, mv: 1500)) == nil)    // mV below the gate
    #expect(await read(window(charging: 0, percent: 50, mv: 5000)) == nil)    // mV above the gate
    #expect(await read(Data([0x01, 0x02])) == nil)                            // short read
}

@Test func missingProcessYieldsNoReading() async {
    let adb = FakeADB(
        answers: [("cmdline", Data("/proc/1\n/init\u{0}\n\n".utf8))],
        window: window(charging: 1, percent: 90, mv: 3149)
    )
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}

@Test func missingLibraryMappingYieldsNoReading() async {
    let adb = FakeADB(
        answers: [("cmdline", procList), ("maps", Data("43e87000-44571000 r-xp 0 1f:03 9 /lib/libc.so\n".utf8))],
        window: window(charging: 1, percent: 90, mv: 3149)
    )
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}
