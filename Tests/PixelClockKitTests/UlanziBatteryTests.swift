import Foundation
import Testing
@testable import PixelClockKit

/// A fake ADB that answers scripted shell output by command substring, records
/// pushes, and hands back canned reader windows in order. No device, no framing.
private actor FakeADB: ADB {
    private var answers: [(match: String, out: Data)]
    private var windows: [Data]
    private var pushed: [(path: String, bytes: Data)] = []
    /// Every stream opened, in order: `shell <command>`, `push <path>`,
    /// `pull <path>` — what a read costs the clock.
    private(set) var streams: [String] = []

    init(answers: [(String, Data)] = [], windows: [Data] = []) {
        self.answers = answers.map { ($0.0, $0.1) }
        self.windows = windows
    }

    func shell(_ command: String) async throws -> Data {
        streams.append("shell \(command)")
        for a in answers where command.contains(a.match) { return a.out }
        return Data()
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {
        streams.append("push \(path)")
        pushed.append((path, bytes))
    }
    func pull(_ path: String) async throws -> Data {
        streams.append("pull \(path)")
        return windows.isEmpty ? Data() : windows.removeFirst()
    }
    func pushes() -> [(path: String, bytes: Data)] { pushed }

    /// What a command containing `match` answers from now on.
    func answer(_ match: String, _ out: Data) {
        answers.removeAll { $0.match == match }
        answers.append((match, out))
    }
    /// More reader windows, served after the ones already queued.
    func queue(_ more: [Data]) { windows += more }
}

private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

/// The base the fixture maps libzkgui at, and the two addresses that follow
/// from it — the pointer to the monitor, and the monitor itself.
private let base: UInt32 = 0x43E8_7000
private let monitorAddress: UInt32 = 0x4220_2840

/// The monitor's own bytes: its vtable pointer, the charging field, the
/// percent the MCU reported and the millivolts beside it.
private func monitor(
    percent: UInt32, charging: UInt32, mv: UInt32, vtable: UInt32 = base &+ 0x0072_1028
) -> Data {
    var d = le32(vtable) + le32(charging) + le32(0)
    d += le32(percent) + le32(mv)
    return d
}

// Both fixtures carry CRLF line endings, because that is what the device
// actually sends: `shell:` is a PTY and turns every \n into \r\n. Fixtures
// written with bare \n hid a real defect — the pid parsed as "670\r", which is
// not a number, so the read silently produced nothing on the live clock.

/// The real sweep output, as the clock answers it: a /proc/<pid> line, then the
/// NUL-joined cmdline, then a blank line.
private let procList = Data(
    "/proc/1\r\n/init\u{0}\r\n\r\n/proc/670\r\n/bin/zkgui\u{0}\r\n\r\n".utf8
)

/// The real maps lines, as read off pid 670 — including what comes BEFORE the
/// library.
///
/// The leading `/bin/zkgui` mappings are the point. The executable is mapped
/// first, at 0x10000, and a parser that fails to split the output into lines
/// happily reports THAT as the library's base. The earlier fixture held only
/// libzkgui lines, so the wrong answer happened to equal the right one and the
/// defect reached the live clock.
private let maps = Data(
    [
        "00010000-00012000 r-xp 00000000 1f:02 43         /bin/zkgui",
        "00021000-00022000 r--p 00001000 1f:02 43         /bin/zkgui",
        "00022000-00023000 rw-p 00002000 1f:02 43         /bin/zkgui",
        "4053b000-40649000 r-xp 00000000 1f:02 82         /lib/libc-2.30.so",
        "43687000-43e87000 rw-p 00000000 00:00 0 ",
        "43e87000-44571000 r-xp 00000000 1f:03 12         /res/lib/libzkgui.so",
        "44571000-44580000 ---p 006ea000 1f:03 12         /res/lib/libzkgui.so",
        "44580000-445b4000 r--p 006e9000 1f:03 12         /res/lib/libzkgui.so",
        "445b4000-445ba000 rw-p 0071d000 1f:03 12         /res/lib/libzkgui.so",
        "beed9000-beefa000 rw-p 00000000 00:00 0          [stack]",
    ].joined(separator: "\r\n").utf8
)

/// The two reads a poll makes: the pointer out of the LogicThread singleton,
/// then the monitor object it points at.
private func fake(pointer: UInt32 = monitorAddress, _ object: Data) -> FakeADB {
    FakeADB(
        answers: [("cmdline", procList), ("maps", maps)],
        windows: [le32(pointer), object]
    )
}

@Test func readsTheLiveMonitorThroughTheSingletonsPointer() async throws {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167))
    let battery = UlanziBattery(adb: adb, helper: Data("ELF-BYTES".utf8))
    let at = Date(timeIntervalSince1970: 1_000)

    let sample = await battery.read(appVersion: "1.1.1", at: at)

    #expect(sample == UlanziBatterySample(percent: 90, charging: true, millivolts: 4167, at: at))
    let pushes = await adb.pushes()
    // The FIRST request asks for the pointer field: the LogicThread singleton
    // at base + 0x733c18, plus the monitor slot at +0x60, four bytes of it.
    let requests = pushes.filter { $0.path == "/tmp/pct-req" }.map(\.bytes)
    #expect(requests.count == 2)
    #expect(requests[0].prefix(4) == le32(base &+ 0x0073_3C18 &+ 0x60))
    #expect(requests[0].dropFirst(4).prefix(4) == le32(4))
    // The SECOND asks for the object the pointer named — not a fixed address.
    #expect(requests[1].prefix(4) == le32(monitorAddress))
    #expect(requests[0].range(of: Data("/proc/670/mem\0".utf8)) != nil)
    // The helper itself is pushed too, since /tmp is wiped on reboot.
    #expect(pushes.contains { $0.path == "/tmp/pct-batt" })
}

// The pointer names an object, and the object says what it is. Reading a
// percent out of whatever happens to sit at that address is how a wrong number
// reaches the panel; the vtable is the firmware's own word that this IS a
// BatteryMonitor.
@Test func anObjectThatIsNotTheMonitorYieldsNoReading() async {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167, vtable: 0xDEAD_BEEF))
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}

@Test func aNullPointerYieldsNoReading() async {
    let adb = fake(pointer: 0, monitor(percent: 90, charging: 1, mv: 4167))
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}

@Test func unknownFirmwareYieldsNoReading() async {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167))
    let battery = UlanziBattery(adb: adb, helper: Data())
    #expect(await battery.read(appVersion: "2.0.0", at: Date()) == nil)
    #expect(await battery.read(appVersion: nil, at: Date()) == nil)
}

@Test func implausibleValuesAreRejected() async {
    func read(_ w: Data) async -> UlanziBatterySample? {
        await UlanziBattery(adb: fake(w), helper: Data()).read(appVersion: "1.1.1", at: Date())
    }
    #expect(await read(monitor(percent: 101, charging: 0, mv: 3000)) == nil)  // percent > 100
    #expect(await read(monitor(percent: 50, charging: 0, mv: 1500)) == nil)   // mV below the gate
    #expect(await read(monitor(percent: 50, charging: 0, mv: 5000)) == nil)   // mV above the gate
    #expect(await read(Data([0x01, 0x02])) == nil)                            // short read
}

@Test func missingProcessYieldsNoReading() async {
    let adb = FakeADB(
        answers: [("cmdline", Data("/proc/1\r\n/init\u{0}\r\n\r\n".utf8))],
        windows: [le32(monitorAddress), monitor(percent: 90, charging: 1, mv: 4167)]
    )
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}

// MARK: - The steady-state read

// Every read used to walk /proc (one `cat` fork per process on the clock),
// cat the maps, push the reader and read two windows: nine ADB streams a
// minute. The process, its load base and the monitor it drives do not move
// while zkgui runs, so after the first read only the monitor window is read —
// and the vtable check says whether the cache still holds.

private func sweeps(_ streams: [String]) -> Int { streams.filter { $0.contains("cmdline") }.count }

@Test func aSecondReadSkipsTheProcessSweep() async throws {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167))
    await adb.queue([monitor(percent: 89, charging: 1, mv: 4160)])
    let battery = UlanziBattery(adb: adb, helper: Data("ELF".utf8))
    _ = await battery.read(appVersion: "1.1.1", at: Date())
    let firstRead = await adb.streams.count

    let second = await battery.read(appVersion: "1.1.1", at: Date(timeIntervalSince1970: 60))

    #expect(second?.percent == 89)
    let streams = await adb.streams
    #expect(sweeps(streams) == 1)
    #expect(streams.filter { $0.contains("maps") }.count == 1)
    #expect(streams.count - firstRead <= 5)
    // The window it read is the monitor's, not the singleton's slot.
    let lastRequest = try #require(await adb.pushes().last { $0.path == "/tmp/pct-req" })
    #expect(lastRequest.bytes.prefix(4) == le32(monitorAddress))
}

// The cache is only allowed because it reads the SAME window the walk's second
// hop reads: the monitor object, all three fields, every poll. A finished
// charge must come through a cached read exactly as through a walk — and the
// panel must say Full off it. Live 2026-09-24: a full walk read charging=1,
// percent=89, 4167 mV with the charger's LED green, which is what the running
// app's cached read showed too.
@Test func aCachedReadOfAFinishedChargeIsTheWalksSampleAndShowsFull() async throws {
    let adb = fake(monitor(percent: 89, charging: 1, mv: 4167))
    await adb.queue([monitor(percent: 89, charging: 1, mv: 4167)])
    let battery = UlanziBattery(adb: adb, helper: Data("ELF".utf8))
    let at = Date(timeIntervalSince1970: 0)
    let walked = await battery.read(appVersion: "1.1.1", at: at)
    let cached = await battery.read(appVersion: "1.1.1", at: at)

    #expect(sweeps(await adb.streams) == 1)          // the second read was the cached one
    #expect(walked == UlanziBatterySample(percent: 89, charging: true, millivolts: 4167, at: at))
    #expect(cached == walked)

    var trajectory = UlanziBatteryTrajectory()
    trajectory.accept(try #require(cached))
    #expect(trajectory.reading?.shownPercent == 100)
}

@Test func aCachedReadThatFailsItsCheckSweepsAgain() async {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167))
    // The cached window reads something that is not the monitor; the re-walk
    // then finds it again.
    await adb.queue([
        monitor(percent: 90, charging: 1, mv: 4167, vtable: 0xDEAD_BEEF),
        le32(monitorAddress), monitor(percent: 88, charging: 0, mv: 4100),
    ])
    let battery = UlanziBattery(adb: adb, helper: Data("ELF".utf8))
    _ = await battery.read(appVersion: "1.1.1", at: Date())

    let second = await battery.read(appVersion: "1.1.1", at: Date())

    #expect(second?.percent == 88)
    #expect(sweeps(await adb.streams) == 2)
}

/// A different zkgui process is a restarted firmware UI — and a restarted UI
/// has dropped every DIY page. The first read ever is not one.
@Test func aNewZkguiProcessIsReportedAsARestart() async {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167))
    let battery = UlanziBattery(adb: adb, helper: Data("ELF".utf8))
    let first = await battery.poll(appVersion: "1.1.1", at: Date())
    #expect(first.sample?.percent == 90)
    #expect(first.zkguiRestarted == false)

    // The old pid's memory reads nothing; the sweep finds pid 671.
    await adb.answer("cmdline", Data("/proc/1\r\n/init\u{0}\r\n\r\n/proc/671\r\n/bin/zkgui\u{0}\r\n\r\n".utf8))
    await adb.queue([Data(), le32(monitorAddress), monitor(percent: 87, charging: 0, mv: 4000)])
    let second = await battery.poll(appVersion: "1.1.1", at: Date())

    #expect(second.sample?.percent == 87)
    #expect(second.zkguiRestarted)
}

@Test func theSameProcessFoundAgainIsNoRestart() async {
    let adb = fake(monitor(percent: 90, charging: 1, mv: 4167))
    let battery = UlanziBattery(adb: adb, helper: Data("ELF".utf8))
    _ = await battery.poll(appVersion: "1.1.1", at: Date())

    await adb.queue([Data(), le32(monitorAddress), monitor(percent: 87, charging: 0, mv: 4000)])
    let second = await battery.poll(appVersion: "1.1.1", at: Date())

    #expect(second.sample?.percent == 87)
    #expect(second.zkguiRestarted == false)
}

@Test func missingLibraryMappingYieldsNoReading() async {
    let adb = FakeADB(
        answers: [
            ("cmdline", procList),
            ("maps", Data("43e87000-44571000 r-xp 0 1f:03 9 /lib/libc.so\r\n".utf8)),
        ],
        windows: [le32(monitorAddress), monitor(percent: 90, charging: 1, mv: 4167)]
    )
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}
