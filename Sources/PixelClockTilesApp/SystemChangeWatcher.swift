import Foundation
import Network

/// Tells this app when the machine's network path changes.
///
/// A tunnel coming up or going down rearranges routes, interfaces and DNS, and
/// this is macOS's own notification that it happened — so the corners follow a
/// VPN within a moment of it moving, rather than at the next turn of a poll.
///
/// It is deliberately a NUDGE and not an answer. The handler is told only that
/// something changed; what changed is worked out afterwards by looking at the
/// process table. That keeps this ignorant of VPNs, which matters because the
/// path also changes when WiFi hiccups, when a cable is plugged in, and when
/// the machine wakes — every one of which is a perfectly good moment to check.
/// The cost of the extra firings is nothing: the lamp custody writes only what
/// moved.
final class NetworkPathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.artk0re.pixelclocktiles.network-path")

    /// Starts watching. The handler fires once straight away with the path as
    /// it stands, which is what puts the corners right at launch.
    func start(_ changed: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { _ in changed() }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

/// Tells this app when the Focus changes, by watching the file macOS writes it
/// to.
///
/// There is no notification for this. `INFocusStatusCenter` answers a boolean
/// when asked and announces nothing, so the only way to hear about a switch as
/// it happens is to watch `Assertions.json` — the same file
/// `DoNotDisturbDatabase` reads to name the active mode.
///
/// The DIRECTORY is watched, not the file. macOS replaces the file rather than
/// editing it in place, and a descriptor held on the old inode goes on
/// reporting nothing about the new one for ever — a bug that would look exactly
/// like Focus switching having stopped working.
final class FocusAssertionsWatcher: @unchecked Sendable {
    /// Derived from the path `DoNotDisturbDatabase` reads, so the two cannot
    /// drift apart.
    static let directory = DoNotDisturbDatabase.assertions.deletingLastPathComponent()

    private let queue = DispatchQueue(label: "dev.artk0re.pixelclocktiles.focus-assertions")
    private let lock = NSLock()
    private var source: (any DispatchSourceFileSystemObject)?

    /// - Returns: whether the watch was established. False means the read was
    ///   refused — opening this directory costs Full Disk Access, and without
    ///   it there is nothing to watch and nothing to be read even if there
    ///   were. The caller keeps its poll, which is what the app ran on before.
    @discardableResult
    func start(
        watching directory: URL = FocusAssertionsWatcher.directory,
        _ changed: @escaping @Sendable () -> Void
    ) -> Bool {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue
        )
        source.setEventHandler { changed() }
        // The descriptor is this source's to close, and only once it is
        // finished with it — closing it alongside `cancel()` would race the
        // queue this source is still draining.
        source.setCancelHandler { close(descriptor) }
        source.resume()

        lock.withLock {
            self.source?.cancel()
            self.source = source
        }
        return true
    }

    func stop() {
        lock.withLock {
            source?.cancel()
            source = nil
        }
    }

    deinit {
        source?.cancel()
    }
}
