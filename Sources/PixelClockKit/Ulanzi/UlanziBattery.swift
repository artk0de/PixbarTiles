import Foundation

/// One poll's raw battery fact, as the firmware itself computed it.
///
/// Deliberately not a `BatteryReading`: the percent is a point sample, and an
/// estimate is a function of the series, which is `UlanziBatteryTrajectory`'s
/// job.
public struct UlanziBatterySample: Sendable, Equatable {
    public let percent: Int
    public let charging: Bool
    public let millivolts: Int
    public let at: Date

    public init(percent: Int, charging: Bool, millivolts: Int, at: Date) {
        self.percent = percent
        self.charging = charging
        self.millivolts = millivolts
        self.at = at
    }
}

/// Reads the TC002's firmware battery figures out of the `zkgui` process
/// memory over ADB.
///
/// The stock HTTP API answers no battery at all, and the cell's characteristics
/// rule out any voltage→percent curve of ours — so the firmware's own computed
/// percent is the only honest number, and this is where it comes from.
///
/// Read-only: it pushes a reader and a request, runs the reader, and parses
/// three `int32`s. Every failure returns nil, because a wrong number on the
/// panel is worse than no number.
public struct UlanziBattery: Sendable {
    /// Where one firmware build keeps the battery, as two hops rather than one
    /// address.
    ///
    /// The first address the spike found — the three `int32`s at `+0x732ee8` —
    /// is `BatteryApp`'s own copy, and `BatteryApp` is the Battery SCREEN. It
    /// is written when that screen updates and at no other time, so a clock
    /// nobody has opened it on serves a figure hours old. Measured: it still
    /// read 3149 mV three hours after the cell had charged to 4167.
    ///
    /// The live figures belong to `BatteryMonitor`, which `LogicThread` drives
    /// every turn of its loop whatever is on screen. The monitor is allocated,
    /// not static, so its address cannot be baked: `LogicThread`'s singleton is
    /// at a fixed place in the library's `.bss`, and it holds the pointer.
    ///
    /// Read off `libzkgui.so` for appVer 1.1.1:
    /// `LogicThread::getInstance` returns `+0x733c18`; `threadLoop` calls
    /// `BatteryMonitor::update` with `[this + 0x60]`; `checkBatteryStatus`
    /// stores `McuManager::queryBatteryPower`'s pair into `[monitor + 0x0c]`
    /// (percent) and `[monitor + 0x10]` (millivolts).
    struct Layout: Sendable {
        /// The `LogicThread` singleton, load-relative.
        let logicThread: UInt32
        /// Where that object keeps the monitor it drives.
        let monitorField: UInt32
        /// The monitor's vtable, load-relative — the firmware's own word that
        /// the pointer landed on a `BatteryMonitor` and not on whatever else
        /// a changed build put there.
        let monitorVTable: UInt32
        let charging: Int
        let percent: Int
        let millivolts: Int
    }

    /// Layouts are build-specific, so an unlisted version reads nothing rather
    /// than reading whatever happens to sit at those addresses.
    static let layouts: [String: Layout] = [
        "1.1.1": Layout(
            logicThread: 0x0073_3C18, monitorField: 0x60, monitorVTable: 0x0072_1028,
            charging: 0x04, percent: 0x0C, millivolts: 0x10
        )
    ]
    /// Enough of the object to reach the millivolts.
    private static let windowLength = 0x14
    /// Where the reader and its parameters live. `/tmp` is a 16 MB tmpfs wiped
    /// on reboot, so both are pushed every poll — idempotent and cheaper than
    /// probing for them.
    private static let helperPath = "/tmp/pct-batt"
    private static let requestPath = "/tmp/pct-req"
    private static let outputPath = "/tmp/pct-out"

    private let adb: any ADB
    private let helper: Data

    public init(adb: any ADB, helper: Data) {
        self.adb = adb
        self.helper = helper
    }

    /// The reader's bytes as shipped in the kit's resource bundle, or nil if it
    /// did not ship. The lookup lives here rather than in the app because the
    /// bundle is the kit's own; a build with no helper simply grows no battery
    /// line.
    public static func bundledHelper() -> Data? {
        guard let url = KitResources.bundle.url(forResource: "pct-batt", withExtension: nil)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public func read(appVersion: String?, at now: Date) async -> UlanziBatterySample? {
        guard let appVersion, let layout = Self.layouts[appVersion] else { return nil }
        do {
            guard let pid = try await resolvePid() else { return nil }
            guard let base = try await resolveBase(pid: pid) else { return nil }
            let mem = "/proc/\(pid)/mem"

            try await adb.push(helper, to: Self.helperPath, mode: 0o755)

            // Hop one: the pointer the LogicThread singleton keeps.
            let slot = try await window(
                at: base &+ layout.logicThread &+ layout.monitorField, length: 4, in: mem
            )
            guard slot.count >= 4 else { return nil }
            let monitor = le32(slot, 0)
            guard monitor != 0 else { return nil }

            // Hop two: the object it points at.
            let out = try await window(at: monitor, length: UInt32(Self.windowLength), in: mem)
            guard out.count >= Self.windowLength else { return nil }
            guard le32(out, 0) == base &+ layout.monitorVTable else { return nil }

            let charging = le32(out, layout.charging) != 0
            let percent = Int(le32(out, layout.percent))
            let millivolts = Int(le32(out, layout.millivolts))
            // A wrong number is worse than none.
            guard (0...100).contains(percent), (2000...4500).contains(millivolts) else { return nil }
            return UlanziBatterySample(
                percent: percent, charging: charging, millivolts: millivolts, at: now
            )
        } catch {
            return nil
        }
    }

    /// One window of the process's memory: the request written, the reader run,
    /// its bytes pulled back.
    ///
    /// Redirected to a file and pulled over sync rather than read off the
    /// shell: `shell:` is a PTY and turns every 0x0a into 0x0d 0x0a, which a
    /// percent of 10 would hit.
    private func window(at address: UInt32, length: UInt32, in mem: String) async throws -> Data {
        try await adb.push(
            request(address: address, length: length, path: mem),
            to: Self.requestPath, mode: 0o644
        )
        _ = try await adb.shell("\(Self.helperPath) > \(Self.outputPath)")
        return try await adb.pull(Self.outputPath)
    }

    /// The pid whose cmdline names zkgui.
    ///
    /// mksh with a stripped busybox: no grep, no head — so the sweep echoes
    /// each `/proc/N` path then its NUL-joined cmdline, and the matching is
    /// done here. argv carries no newline, so splitting the raw bytes on 0x0a
    /// keeps each cmdline in one piece.
    ///
    /// Every line is trimmed first, because `shell:` is a PTY: it turns each
    /// `\n` into `\r\n`, so a line arrives as `/proc/670\r` and parsing that
    /// as a number yields nothing at all.
    private func resolvePid() async throws -> Int? {
        let out = try await adb.shell(
            "for d in /proc/[0-9]*; do echo $d; cat $d/cmdline; echo; done"
        )
        var pid: Int?
        for line in out.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("/proc/") {
                pid = Int(text.dropFirst("/proc/".count))
            } else if text.contains("zkgui"), let found = pid {
                return found
            }
        }
        return nil
    }

    /// The start address of the `r-xp` libzkgui.so mapping — the load base the
    /// offset is relative to. Read every poll, never baked: the loader's
    /// placement does not survive a reboot.
    /// Split on the BYTE, not on a `Character`.
    ///
    /// `shell:` is a PTY, so lines end `\r\n` — and in Swift `\r\n` is a single
    /// grapheme cluster, which means `String.split(separator: "\n")` does not
    /// match it and hands back the whole output as ONE line. Measured against
    /// the clock, that made the maps parse read the first mapping in the file
    /// (`/bin/zkgui` at 0x10000) instead of the library's, and every read came
    /// back empty.
    private func lines(of data: Data) -> [String] {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func resolveBase(pid: Int) async throws -> UInt32? {
        let out = try await adb.shell("cat /proc/\(pid)/maps")
        for line in lines(of: out) {
            guard line.hasSuffix("libzkgui.so"), line.contains("r-xp") else { continue }
            let start = line.split(separator: "-").first.map(String.init) ?? ""
            if let base = UInt32(start, radix: 16) { return base }
        }
        return nil
    }

    /// The reader's parameters: `u32` address, `u32` length, NUL-terminated
    /// path. The reader carries none of this itself, so one shipped binary
    /// serves any pid and any load address.
    private func request(address: UInt32, length: UInt32, path: String) -> Data {
        var d = Data()
        withUnsafeBytes(of: address.littleEndian) { d.append(Data($0)) }
        withUnsafeBytes(of: length.littleEndian) { d.append(Data($0)) }
        d.append(Data(path.utf8))
        d.append(0)
        return d
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8)
            | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }
}
