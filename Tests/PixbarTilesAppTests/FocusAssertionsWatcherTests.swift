import Foundation
import Testing
@testable import PixbarTilesApp

/// Counts firings from whichever queue the watcher calls back on.
private final class Firings: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

// The event this has to catch is a file APPEARING, not a file being edited:
// macOS writes the assertions out fresh and renames them into place on every
// Focus switch. Posed against a temporary directory of the same shape, because
// the real one is behind Full Disk Access — which the signed app holds and the
// suite must never need.
@MainActor
@Test func aFileAppearingInTheWatchedDirectoryIsNoticed() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("focus-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fired = Firings()
    let watcher = FocusAssertionsWatcher()
    defer { watcher.stop() }

    #expect(watcher.start(watching: directory) { fired.bump() })
    try Data("{}".utf8).write(to: directory.appendingPathComponent("Assertions.json"))

    #expect(await waitUntil { fired.count > 0 })
}

// The case that decides what happens on somebody else's Mac. Opening that
// directory costs Full Disk Access; without it there is nothing to watch, and
// the honest answer is to say so and let the caller keep the minute poll it ran
// on before. A watcher that returned true and then never fired would look
// exactly like a Focus that never changes.
@Test func aDirectoryThatCannotBeOpenedIsReportedRatherThanPretended() {
    let watcher = FocusAssertionsWatcher()
    defer { watcher.stop() }

    let nowhere = URL(fileURLWithPath: "/nowhere/at/all/\(UUID().uuidString)")

    #expect(watcher.start(watching: nowhere) {} == false)
}

@MainActor
@Test func stoppingEndsTheWatch() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("focus-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fired = Firings()
    let watcher = FocusAssertionsWatcher()
    #expect(watcher.start(watching: directory) { fired.bump() })
    try Data("{}".utf8).write(to: directory.appendingPathComponent("first.json"))
    #expect(await waitUntil { fired.count > 0 })

    watcher.stop()
    let afterStop = fired.count
    try Data("{}".utf8).write(to: directory.appendingPathComponent("second.json"))
    // No "eventually" available for a negative, so this waits a beat and then
    // asserts nothing arrived — which is the most a stopped watcher can be
    // asked to prove.
    try await Task.sleep(for: .milliseconds(200))

    #expect(fired.count == afterStop)
}
