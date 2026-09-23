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
    /// libzkgui load-relative offset of the charging `int32`, per firmware
    /// `appVer`. Percent is +4, millivolts +8; the window is 12 bytes.
    ///
    /// Offsets are build-specific, so an unlisted version reads nothing rather
    /// than reading whatever happens to sit there. Measured on the live clock:
    /// base 0x43e87000 + 0x732ee8 held charging=1, percent=90, mV=3149 while
    /// the firmware reported `Battery: 90%, V:3149mv, charging=1`.
    static let offsets: [String: UInt32] = ["1.1.1": 0x0073_2EE8]
    private static let windowLength = 12
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

    public func read(appVersion: String?, at now: Date) async -> UlanziBatterySample? {
        guard let appVersion, let offset = Self.offsets[appVersion] else { return nil }
        do {
            guard let pid = try await resolvePid() else { return nil }
            guard let base = try await resolveBase(pid: pid) else { return nil }

            try await adb.push(helper, to: Self.helperPath, mode: 0o755)
            try await adb.push(
                request(address: base &+ offset, path: "/proc/\(pid)/mem"),
                to: Self.requestPath, mode: 0o644
            )
            // Redirected to a file and pulled back: `shell:` is a PTY and turns
            // every 0x0a into 0x0d 0x0a, which a percent of 10 would hit.
            _ = try await adb.shell("\(Self.helperPath) > \(Self.outputPath)")
            let out = try await adb.pull(Self.outputPath)
            guard out.count >= Self.windowLength else { return nil }

            let charging = le32(out, 0) != 0
            let percent = Int(le32(out, 4))
            let millivolts = Int(le32(out, 8))
            // A wrong number is worse than none.
            guard (0...100).contains(percent), (2000...4500).contains(millivolts) else { return nil }
            return UlanziBatterySample(
                percent: percent, charging: charging, millivolts: millivolts, at: now
            )
        } catch {
            return nil
        }
    }

    /// The pid whose cmdline names zkgui.
    ///
    /// mksh with a stripped busybox: no grep, no head — so the sweep echoes
    /// each `/proc/N` path then its NUL-joined cmdline, and the matching is
    /// done here. argv carries no newline, so splitting the raw bytes on 0x0a
    /// keeps each cmdline in one piece.
    private func resolvePid() async throws -> Int? {
        let out = try await adb.shell(
            "for d in /proc/[0-9]*; do echo $d; cat $d/cmdline; echo; done"
        )
        var pid: Int?
        for line in out.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let text = String(decoding: line, as: UTF8.self)
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
    private func resolveBase(pid: Int) async throws -> UInt32? {
        let out = try await adb.shell("cat /proc/\(pid)/maps")
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            guard line.contains("libzkgui.so"), line.contains("r-xp") else { continue }
            let start = line.split(separator: "-").first.map(String.init) ?? ""
            if let base = UInt32(start, radix: 16) { return base }
        }
        return nil
    }

    /// The reader's parameters: `u32` address, `u32` length, NUL-terminated
    /// path. The reader carries none of this itself, so one shipped binary
    /// serves any pid and any load address.
    private func request(address: UInt32, path: String) -> Data {
        var d = Data()
        withUnsafeBytes(of: address.littleEndian) { d.append(Data($0)) }
        withUnsafeBytes(of: UInt32(Self.windowLength).littleEndian) { d.append(Data($0)) }
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
