import Foundation
import PixelClockKit

/// The device side of a TC002 battery read, as the reader actually walks it.
///
/// Every app-side test that wants a reading needs the same two hops — the
/// monitor pointer out of the LogicThread singleton, then the object it names,
/// carrying its own vtable so the reader can tell a BatteryMonitor from
/// whatever else a changed build might leave at that address. Kept in one place
/// so the shape of the read lives in one file rather than in three fakes.
enum BatteryFixture {
    /// The base the maps line below loads libzkgui at, and the addresses that
    /// follow from it.
    static let base: UInt32 = 0x43E8_7000
    static let monitorAddress: UInt32 = 0x4220_2840
    static var vtable: UInt32 { base &+ 0x0072_1028 }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// The monitor's own bytes: vtable, charging flag, percent, millivolts.
    static func monitor(percent: UInt32, charging: UInt32, mv: UInt32 = 3600) -> Data {
        le32(vtable) + le32(charging) + le32(0) + le32(percent) + le32(mv)
    }

    /// The sweep output and the maps line, both CRLF — `shell:` is a PTY.
    static func shellAnswer(_ command: String) -> Data {
        if command.contains("cmdline") { return Data("/proc/670\r\n/bin/zkgui\u{0}\r\n\r\n".utf8) }
        if command.contains("maps") {
            return Data("43e87000-44571000 r-xp 00000000 1f:03 12 /res/lib/libzkgui.so\r\n".utf8)
        }
        return Data()
    }
}

/// An ADB that answers the sweep and the maps, then hands back the reader's two
/// windows in the order it asks for them.
actor FakeBatteryADB: ADB {
    private let percent: UInt32
    private let charging: UInt32
    private var pulls = 0

    init(percent: UInt32, charging: UInt32) {
        self.percent = percent
        self.charging = charging
    }

    func shell(_ command: String) async throws -> Data { BatteryFixture.shellAnswer(command) }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {}
    func pull(_ path: String) async throws -> Data {
        pulls += 1
        if pulls == 1 { return BatteryFixture.le32(BatteryFixture.monitorAddress) }
        return BatteryFixture.monitor(percent: percent, charging: charging)
    }
}
