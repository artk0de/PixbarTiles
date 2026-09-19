import Darwin
import Foundation
import PixelClockKit

/// Everything running on this machine, by executable path.
///
/// A protocol so the rule below can be posed to a captured process table
/// instead of to the machine the suite happens to run on — which is the only
/// way to test "Amnezia is up and Pritunl is not" without asking somebody to
/// go and click things.
protocol RunningProcessListing: Sendable {
    func executablePaths() -> [String]
}

/// The real process table, read through the kernel.
///
/// `sysctl` for the list of pids and `proc_pidpath` for each path — both public
/// C calls, no privileges, no subprocess. Spawning `ps` was the obvious
/// alternative and was rejected once this was measured to work: on this machine
/// 612 of 613 paths came back including the root-owned `pritunl-openvpn`, and
/// the one refusal was not a VPN. A menu-bar app forking a shell on every
/// network blip is a worse thing to own.
struct SystemProcessList: RunningProcessListing {
    func executablePaths() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Room to spare, because processes start between the two calls and a
        // buffer sized exactly by the first one comes back ENOMEM. The count
        // that matters is the one the SECOND call reports.
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &table, &size, nil, 0) == 0 else { return [] }

        var paths: [String] = []
        paths.reserveCapacity(size / stride)
        // `PROC_PIDPATHINFO_MAXSIZE`, which the C header defines as
        // `4 * MAXPATHLEN` and Swift does not import. Written out rather than
        // guessed small: `proc_pidpath` refuses a buffer under that size
        // outright rather than truncating into it.
        var buffer = [UInt8](repeating: 0, count: 4096)
        for process in table.prefix(size / stride) {
            let pid = process.kp_proc.p_pid
            guard pid > 0 else { continue }
            let length = buffer.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            // A refusal is a process this user may not look at, which is not a
            // VPN of theirs — so it is skipped rather than reported.
            guard length > 0 else { continue }
            paths.append(String(decoding: buffer[..<Int(length)], as: UTF8.self))
        }
        return paths
    }
}

/// Whether a VPN is carrying traffic, as far as this machine will say.
///
/// "As far as it will say" is the honest limit and it is worth stating: this
/// sees that a tunnel process EXISTS, which is evidence of intent rather than
/// proof of throughput. A wedged tunnel binary reads as up. The authoritative
/// alternatives were each tried and each failed for its own reason —
/// `pritunl-client list` comes back empty on this machine because the GUI keeps
/// its profiles elsewhere, `/var/run/amneziawg/*.sock` exists only while
/// Amnezia is in WireGuard mode, and reading the route table means hard-coding
/// subnets out of somebody's profile.
struct VPNPresence: Sendable {
    private let processes: any RunningProcessListing

    init(processes: any RunningProcessListing = SystemProcessList()) {
        self.processes = processes
    }

    /// One scan per question rather than one per reading. The scan was measured
    /// at a few milliseconds and only runs when the network or the Focus
    /// changes, so a second pass costs less than the machinery to avoid it.
    func isUp(_ vpn: WatchedVPN) -> Bool {
        processes.executablePaths().contains { path in
            guard path.hasPrefix(vpn.bundle) else { return false }
            guard let binary = path.split(separator: "/").last else { return false }
            return vpn.tunnelBinaries.contains(String(binary))
        }
    }
}
