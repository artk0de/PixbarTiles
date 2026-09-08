import Foundation
import Testing
@testable import AwtrixKit

// MARK: - Doubles

/// Answers for whatever address it is asked about, and remembers being asked.
///
/// Lock-guarded for `RecordingTransport`'s reason rather than out of caution:
/// the probe is called from a task the relocation owns, and the test reads the
/// record from the main actor. `Mutex` would satisfy the checker without
/// `@unchecked`, but it is macOS 15+ and this package floors at macOS 14.
final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private let answer: String?

    /// - Parameter answer: the uid the address replies with, or nil for an
    ///   address that does not answer at all.
    init(answering answer: String?) {
        self.answer = answer
    }

    var hosts: [String] { lock.withLock { asked } }

    var probe: @Sendable (String) async -> String? {
        { [self] host in
            lock.withLock { asked.append(host) }
            return answer
        }
    }
}

/// Polls until the condition holds or the budget runs out.
///
/// A third copy of this shape in the target, and deliberately not a fourth
/// statement of the NUMBER: `waitBudget` is the one constant, which is the part
/// that actually drifted when it was written out by hand per file.
@discardableResult
@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool, limit: TimeInterval? = nil
) async -> Bool {
    let deadline = Date().addingTimeInterval(waitBudget(limit))
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A relocation wired to fakes, with the browse it will run held by the test.
@MainActor
private func relocation(
    browsing: FakeBonjourBrowser,
    browseClock: SettleClock = SettleClock(),
    probe: ProbeLog,
    attemptClock: SettleClock
) -> DeviceRelocation {
    DeviceRelocation(
        browser: { DeviceBrowser(browsing: { browsing }, sleep: browseClock.sleep) },
        probe: probe.probe,
        sleep: attemptClock.sleep
    )
}

// MARK: - Finding the clock again

// The defect this whole type exists for: the lease moved, every poll is
// spending the full transport timeout on an address with nothing behind it, and
// the name the firmware advertises has been pointing at the new address the
// entire time.
@Test @MainActor func aClockThatMovedIsFoundAtItsOwnName() async {
    let browsing = FakeBonjourBrowser()
    let probe = ProbeLog(answering: "awtrix_a07f9c")
    let subject = relocation(browsing: browsing, probe: probe, attemptClock: SettleClock())

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { browsing.liveBrowses == 1 })
    browsing.emit(.ready)
    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(await found == "awtrix_a07f9c.local")
    #expect(probe.hosts == ["awtrix_a07f9c.local"])
}

// An outage that is the clock being unplugged rather than the clock having
// moved. There is nothing to find, and the app stays pointed where it was.
@Test @MainActor func anEmptyNetworkMovesTheAppNowhere() async {
    let browsing = FakeBonjourBrowser()
    let browseClock = SettleClock()
    let probe = ProbeLog(answering: "awtrix_a07f9c")
    let subject = relocation(
        browsing: browsing, browseClock: browseClock, probe: probe,
        attemptClock: SettleClock()
    )

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { browsing.liveBrowses == 1 })
    browsing.emit(.ready)
    #expect(await waitUntil { browseClock.parked == 1 })
    browseClock.elapse()

    #expect(await found == nil)
    #expect(probe.hosts.isEmpty)
}

// A refusal is not an empty network, and it is certainly not a licence to move:
// nothing was looked at, so nothing was ruled out.
@Test @MainActor func aRefusedBrowseMovesTheAppNowhere() async {
    let browsing = FakeBonjourBrowser()
    let probe = ProbeLog(answering: "awtrix_a07f9c")
    let subject = relocation(browsing: browsing, probe: probe, attemptClock: SettleClock())

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { browsing.liveBrowses == 1 })
    browsing.emit(.denied)

    #expect(await found == nil)
    #expect(probe.hosts.isEmpty)
}

// MARK: - Proving the address before moving onto it

// `<name>.local` is this app's own construction and mDNS is a cache. An address
// that does not answer is not somewhere to move the monitor, the custody and
// every connector onto.
@Test @MainActor func anAddressThatDoesNotAnswerIsNotMovedOnto() async {
    let browsing = FakeBonjourBrowser()
    let probe = ProbeLog(answering: nil)
    let subject = relocation(browsing: browsing, probe: probe, attemptClock: SettleClock())

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { browsing.liveBrowses == 1 })
    browsing.emit(.ready)
    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(await found == nil)
    #expect(probe.hosts == ["awtrix_a07f9c.local"])
}

// A stale mDNS answer pointing at whatever took the old lease. The address
// replies, so reachability alone would have accepted it — the name it replies
// with is what catches it.
@Test @MainActor func anAddressThatAnswersForAnotherClockIsNotMovedOnto() async {
    let browsing = FakeBonjourBrowser()
    let probe = ProbeLog(answering: "awtrix_ff0102")
    let subject = relocation(browsing: browsing, probe: probe, attemptClock: SettleClock())

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { browsing.liveBrowses == 1 })
    browsing.emit(.ready)
    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(await found == nil)
}

// MARK: - Nothing outlives the attempt

// The rule the panel's own browse gate was written to enforce, kept here by
// construction instead: this type starts a browse nobody else can see, so if it
// does not take it down there is nothing left that can. A browse left running
// puts multicast on the network for the life of the process.
@Test @MainActor func theBrowseIsStoppedOnceItHasAnswered() async {
    let browsing = FakeBonjourBrowser()
    let probe = ProbeLog(answering: "awtrix_a07f9c")
    let subject = relocation(browsing: browsing, probe: probe, attemptClock: SettleClock())

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { browsing.liveBrowses == 1 })
    browsing.emit(.ready)
    browsing.emit(.results(["awtrix_a07f9c"]))
    _ = await found

    #expect(browsing.liveBrowses == 0)
}

// The case the browse's own settle window cannot answer for. That window is
// armed by `.ready`, so a browser that never comes up never arms it and never
// says anything — and an attempt waiting on it would hold an NWBrowser for the
// life of the process, which is the exact defect this feature must not
// reintroduce.
@Test @MainActor func aBrowseThatNeverAnswersIsGivenUpOnRatherThanLeftRunning() async {
    let browsing = FakeBonjourBrowser()
    let attemptClock = SettleClock()
    let probe = ProbeLog(answering: "awtrix_a07f9c")
    let subject = relocation(browsing: browsing, probe: probe, attemptClock: attemptClock)

    async let found = subject.relocatedHost(remembering: "awtrix_a07f9c")
    #expect(await waitUntil { attemptClock.parked == 1 })
    attemptClock.elapse()

    #expect(await found == nil)
    #expect(browsing.liveBrowses == 0)
}

// The attempt's deadline has to outlast the browse's own, or it cuts off a
// browse that was about to answer and reports "nothing found" about a network
// it stopped listening to.
@Test @MainActor func theAttemptOutlastsTheBrowsesOwnSettleWindow() {
    #expect(DeviceRelocation.attemptWindow > DeviceBrowser.settleWindow)
}
