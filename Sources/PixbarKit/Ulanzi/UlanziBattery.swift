import Foundation

/// One poll's raw battery fact, as the firmware itself computed it.
///
/// Deliberately not a `BatteryReading`: the percent is a point sample, and an
/// estimate is a function of the series, which is `UlanziBatteryTrajectory`'s
/// job.
public struct UlanziBatterySample: Sendable, Equatable, Codable {
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

/// One battery read: the sample, if any, and whether it found a different
/// zkgui process than the read before — the firmware UI restarted.
public struct UlanziBatteryPoll: Sendable, Equatable {
    public let sample: UlanziBatterySample?
    public let zkguiRestarted: Bool

    public init(sample: UlanziBatterySample?, zkguiRestarted: Bool) {
        self.sample = sample
        self.zkguiRestarted = zkguiRestarted
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
///
/// The first read walks the whole way — the /proc sweep (a `cat` fork per
/// process on the clock), the maps, the reader pushed, two windows: nine ADB
/// streams. The process, its load base and the monitor object do not move
/// while zkgui runs, so they are kept, and every later read is the monitor's
/// window alone (three streams). The vtable check that already guards the
/// read is what says the cache still holds; a read that fails it walks the
/// whole way again.
public actor UlanziBattery {
    /// Where the last full walk found the monitor.
    private struct Found: Equatable {
        let pid: Int
        let base: UInt32
        let monitor: UInt32
    }
    private var found: Found?
    /// The process and load base the last walk resolved — kept through a
    /// failed read, so the next walk can tell a new zkgui from the old one.
    private var lastProcess: (pid: Int, base: UInt32)?

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
    /// on reboot, so the reader is pushed on every full walk and the request
    /// on every window. A cached read against a rebooted clock finds no reader
    /// and an empty output, fails its check, and walks — which pushes it back.
    private static let helperPath = "/tmp/pbt-batt"
    private static let requestPath = "/tmp/pbt-req"
    private static let outputPath = "/tmp/pbt-out"

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
        guard let url = KitResources.bundle.url(forResource: "pbt-batt", withExtension: nil)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public func read(appVersion: String?, at now: Date) async -> UlanziBatterySample? {
        await poll(appVersion: appVersion, at: now).sample
    }

    /// One read, and whether it had to find a DIFFERENT zkgui than the last
    /// walk did — a restarted firmware UI, which has dropped every DIY page.
    /// The first walk ever is not a restart: there is nothing to differ from.
    public func poll(appVersion: String?, at now: Date) async -> UlanziBatteryPoll {
        guard let appVersion, let layout = Self.layouts[appVersion] else {
            return UlanziBatteryPoll(sample: nil, zkguiRestarted: false)
        }
        // THE CACHE INVARIANT. What is kept is only what locates the monitor
        // — the pid, the load base, the monitor's address. What is READ, every
        // poll, cached or walked, is the same thing the walk's second hop reads:
        // the monitor's whole window, vtable, charging flag, percent and
        // millivolts together. The firmware has no other battery state to read
        // — every word past the millivolts is zero or a tick counter, there is
        // no "full" flag — so a cached read loses nothing a walk would see.
        // Verified on the live clock 2026-09-24: a fresh walk and the running
        // app's cached read both gave charging=1, percent=89, 4167 mV.
        //
        // Never cache a FIELD (percent, charging, millivolts) or skip the
        // window on a "nothing changed" guess: the panel's Full is derived from
        // all three read together (`UlanziBatteryTrajectory.shown`), and a
        // stale one of them is a wrong figure. A finished charge that reads
        // below 100 is the trajectory's rule, not this cache — see
        // `UlanziBatteryTrajectory.ceilingPercent` before touching either.
        if let found {
            let out = try? await window(
                at: found.monitor, length: UInt32(Self.windowLength), in: "/proc/\(found.pid)/mem"
            )
            if let out, let sample = sample(out, base: found.base, layout: layout, at: now) {
                return UlanziBatteryPoll(sample: sample, zkguiRestarted: false)
            }
            self.found = nil
        }
        return await walk(layout: layout, at: now)
    }

    /// The whole way: the process, its load base, the reader, both hops.
    private func walk(layout: Layout, at now: Date) async -> UlanziBatteryPoll {
        var restarted = false
        do {
            guard let pid = try await resolvePid() else { return UlanziBatteryPoll(sample: nil, zkguiRestarted: false) }
            guard let base = try await resolveBase(pid: pid) else {
                return UlanziBatteryPoll(sample: nil, zkguiRestarted: false)
            }
            if let last = lastProcess, last.pid != pid || last.base != base { restarted = true }
            lastProcess = (pid, base)
            let mem = "/proc/\(pid)/mem"

            try await adb.push(helper, to: Self.helperPath, mode: 0o755)

            // Hop one: the pointer the LogicThread singleton keeps.
            let slot = try await window(
                at: base &+ layout.logicThread &+ layout.monitorField, length: 4, in: mem
            )
            guard slot.count >= 4 else { return UlanziBatteryPoll(sample: nil, zkguiRestarted: restarted) }
            let monitor = le32(slot, 0)
            guard monitor != 0 else { return UlanziBatteryPoll(sample: nil, zkguiRestarted: restarted) }

            // Hop two: the object it points at.
            let out = try await window(at: monitor, length: UInt32(Self.windowLength), in: mem)
            let read = sample(out, base: base, layout: layout, at: now)
            if read != nil { found = Found(pid: pid, base: base, monitor: monitor) }
            return UlanziBatteryPoll(sample: read, zkguiRestarted: restarted)
        } catch {
            return UlanziBatteryPoll(sample: nil, zkguiRestarted: restarted)
        }
    }

    /// The monitor's window as a sample — or nil when it is short, is not a
    /// `BatteryMonitor` by its vtable, or reads implausibly.
    private func sample(_ out: Data, base: UInt32, layout: Layout, at now: Date) -> UlanziBatterySample? {
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
