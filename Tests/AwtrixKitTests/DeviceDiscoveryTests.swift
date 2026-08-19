import Foundation
import Network
import Testing
@testable import AwtrixKit

// MARK: - Doubles

/// A browser that reports whatever a test hands it, and counts what it was
/// asked to do.
///
/// Every browsing test goes through this rather than `NetworkBonjourBrowser`,
/// for two reasons that are not convenience: a real browse needs a device on
/// the LAN, which is a test that fails in CI for the wrong reason, and a real
/// browse cannot be made to answer `.denied` at all without revoking the
/// machine's Local Network permission.
@MainActor
final class FakeBonjourBrowser: BonjourBrowsing {
    private(set) var starts = 0
    private var handlers: [@MainActor (BonjourEvent) -> Void] = []

    /// Browses begun and not yet cancelled.
    ///
    /// Held as a list rather than as one slot so that more than one at a time
    /// is representable, because that is the real defect a restart can ship:
    /// `NWBrowser` reports per browse, and `stop` can only cancel the browser
    /// it is currently holding — the one it dropped goes on reporting for the
    /// life of the app with nothing able to stop it.
    var liveBrowses: Int { handlers.count }

    func start(onEvent: @escaping @MainActor (BonjourEvent) -> Void) {
        starts += 1
        handlers.append(onEvent)
    }

    func cancel() { handlers.removeAll() }

    /// Delivers what a real browser would have delivered — to every browse
    /// still running, as the framework would.
    func emit(_ event: BonjourEvent) { handlers.forEach { $0(event) } }
}

/// Stands in for `Task.sleep` so the settle window can be run out on demand.
///
/// A cancelled sleeper throws exactly as the real one does: `DeviceBrowser.stop`
/// relies on that throw to abandon the window, so a fake that swallowed it would
/// be testing a different loop from the one that ships.
final class SettleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var requested: [TimeInterval] = []
    private var nextId = 0

    /// Every duration asked for, in call order.
    var durations: [TimeInterval] { lock.withLock { requested } }
    var parked: Int { lock.withLock { sleepers.count } }

    /// Runs the window out.
    func elapse() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = Array(sleepers.values)
            sleepers = [:]
            return all
        }
        held.forEach { $0.resume() }
    }

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in try await park(seconds) }
    }

    private func park(_ seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in
            nextId += 1
            requested.append(seconds)
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if cancelled.contains(id) { return true }
                    sleepers[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let held = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                cancelled.insert(id)
                return sleepers.removeValue(forKey: id)
            }
            held?.resume(throwing: CancellationError())
        }
    }
}

/// Polls until the condition holds or the wait runs out. Returns rather than
/// asserting, so the failure is reported by the expectation that named the rule.
///
/// The budget is `pollingBudget`, never a number written here: this helper is
/// the one that was left at two seconds when its twin was raised to five.
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

/// A browser wired to a fake, brought up, with the settle window parked and
/// waited for.
///
/// `.ready` is emitted because that is what opens the window — `start()` alone
/// no longer does, since a browse that never comes up has said nothing about
/// the network. The wait is not decoration either: the window opens on a task,
/// and a test that ran `elapse()` before that task parked would run out a
/// window nobody was waiting on and prove nothing.
@MainActor
private func startedBrowser(
    browsing: FakeBonjourBrowser, clock: SettleClock
) async -> DeviceBrowser {
    // The shipped window, not one the test picked: `clock.durations` below is
    // then evidence about the constant this app actually browses with.
    let subject = DeviceBrowser(browsing: { browsing }, sleep: clock.sleep)
    subject.start()
    browsing.emit(.ready)
    #expect(await waitUntil { clock.parked == 1 })
    return subject
}

private let printer = "Brother HL-L2350DW"

// MARK: - Which Bonjour instances are ours

@Test func awtrixInstancesAreRecognisedWhateverTheirCase() {
    #expect(DeviceDiscovery.isAwtrixInstance("awtrix_a07f9c"))
    #expect(DeviceDiscovery.isAwtrixInstance("AWTRIX_A07F9C"))
}

@Test func otherBonjourInstancesAreIgnored() {
    #expect(!DeviceDiscovery.isAwtrixInstance(printer))
    #expect(!DeviceDiscovery.isAwtrixInstance(""))
    // A prefix, not a substring: the firmware names itself `awtrix_<suffix>`,
    // and anything else that merely contains the word is somebody else's box.
    #expect(!DeviceDiscovery.isAwtrixInstance("my-awtrix-clone"))
}

// A prefix, and only a prefix. `my-awtrix-clone` — the fixture above — has no
// underscore in it at all, so it is turned away by the separator rule and says
// nothing about where in the string the match had to be: swapping `hasPrefix`
// for `contains` kept every expectation above green. A neighbour that named
// itself after the clock it sits next to is the case that tells them apart.
@Test func aNameThatMerelyContainsTheFirmwaresIsNotADevice() {
    #expect(!DeviceDiscovery.isAwtrixInstance("kitchen-awtrix_a07f9c"))
    #expect(!DeviceDiscovery.isAwtrixInstance("Sonos awtrix_ff0102 bridge"))
}

// The separator is part of the name, not decoration around it.
@Test func aNameWithoutTheUnderscoreIsNotADevice() {
    #expect(!DeviceDiscovery.isAwtrixInstance("awtrix"))
    #expect(!DeviceDiscovery.isAwtrixInstance("awtrixa07f9c"))
}

// `awtrix_` with nothing after it carries no MAC suffix, so it cannot be an
// instance of the firmware — a bare `hasPrefix` accepts it.
@Test func aNameWithNoMacSuffixIsNotADevice() {
    #expect(!DeviceDiscovery.isAwtrixInstance("awtrix_"))
    #expect(DeviceDiscovery.isAwtrixInstance("awtrix_a"))
}

// MARK: - What a browser failure means

// The whole point of the state below. Local Network permission arrives as a
// DNS-layer refusal, not as an empty result set, and folding it into "no
// devices found" tells the user the network is empty when the real answer is
// that they said no.
@Test func aRefusedLocalNetworkPermissionIsNotAnEmptyNetwork() {
    let refused = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))

    #expect(DeviceDiscovery.failure(for: refused) == .denied)
}

// The other half of the same family: `PolicyDenied` is the user's answer,
// `NotPermitted` is a policy that never asked them. Both mean the browse will
// never report anything, and neither means an empty network.
@Test func aPolicyThatForbidsBrowsingIsDeniedToo() {
    let forbidden = NWError.dns(DNSServiceErrorType(kDNSServiceErr_NotPermitted))

    #expect(DeviceDiscovery.failure(for: forbidden) == .denied)
}

@Test func anyOtherBrowserErrorIsReportedAsItself() {
    let broken = NWError.dns(DNSServiceErrorType(kDNSServiceErr_Unknown))

    guard case let .failed(reason) = DeviceDiscovery.failure(for: broken) else {
        Issue.record("expected a failure, got \(DeviceDiscovery.failure(for: broken))")
        return
    }
    // The reason is the system's own text. A permission dialog offered for a
    // failure that has nothing to do with permission sends the user to the
    // wrong settings pane.
    #expect(reason.contains("65537"))
}

@Test func aTransportLevelBrowserErrorIsAFailureRatherThanARefusal() {
    #expect(DeviceDiscovery.failure(for: .posix(.ENETDOWN)) != .denied)
}

// MARK: - Three answers, not one empty list

@Test @MainActor func discoveryIsIdleUntilItIsAsked() {
    let browsing = FakeBonjourBrowser()

    let subject = DeviceBrowser(browsing: { browsing }, sleep: { _ in })

    #expect(subject.state == .idle)
    #expect(browsing.starts == 0)
    #expect(browsing.liveBrowses == 0)
}

@Test @MainActor func startingDiscoveryBrowsesAndSaysSoIsSearching() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()

    let subject = await startedBrowser(browsing: browsing, clock: clock)

    #expect(subject.state == .searching)
    // A discovery test that would also pass with no browser at all is the
    // shape of defect this branch keeps shipping.
    #expect(browsing.starts == 1)
    #expect(browsing.liveBrowses == 1)
}

// mDNS has no "that is all". Verified against the real stack: a browse for a
// service type nobody advertises reports `.ready` and then never calls back at
// all, so silence is the same shape whether the network is empty or the answer
// is still in flight. The window is the only thing that can tell them apart.
@Test @MainActor func aBrowserThatHasNotAnsweredYetIsNotAnEmptyNetwork() async {
    let clock = SettleClock()

    let subject = await startedBrowser(browsing: FakeBonjourBrowser(), clock: clock)

    #expect(subject.state == .searching)
    #expect(subject.state != .listed([]))
    #expect(clock.durations == [DeviceBrowser.settleWindow])
    // Three seconds, and the panel says "Looking" for every one of them: long
    // enough for mDNS's own retries at one and two seconds, short enough that
    // an empty network is answered rather than left spinning.
    #expect(DeviceBrowser.settleWindow == 3)
}

@Test @MainActor func silenceBecomesAnEmptyNetworkOnceTheWindowRunsOut() async {
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: FakeBonjourBrowser(), clock: clock)

    clock.elapse()

    #expect(await waitUntil { subject.state == .listed([]) })
}

@Test @MainActor func aRefusalIsReportedAsDeniedRatherThanAsNoDevices() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.denied)

    #expect(subject.state == .denied)
    #expect(subject.state != .listed([]))
}

// The window is what turns silence into "nothing here", and a refusal is
// exactly the case that produces silence. Left ungated, the window would
// overwrite the one answer the user can act on with the one they cannot.
@Test @MainActor func aRefusalSurvivesTheWindowRunningOut() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)
    browsing.emit(.denied)

    clock.elapse()

    #expect(await waitUntil({ subject.state != .denied }, limit: 0.05) == false)
}

@Test @MainActor func aFailedBrowseCarriesItsReason() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.failed("interface went away"))

    #expect(subject.state == .failed("interface went away"))
}

@Test @MainActor func aFailedBrowseSurvivesTheWindowRunningOutToo() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)
    browsing.emit(.failed("interface went away"))

    clock.elapse()

    #expect(await waitUntil({ subject.state == .listed([]) }, limit: 0.05) == false)
}

// A browser going `.ready` says the browse is up, not that the network is
// empty — it is what arrives before every one of the cases above.
@Test @MainActor func aReadyBrowserIsStillSearching() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.ready)

    #expect(subject.state == .searching)
    // And one deadline, not one per `.ready`. A browse that reports itself up
    // more than once would otherwise stack windows, and the last one to land
    // would overwrite whatever the browse had found in the meantime.
    #expect(await waitUntil({ clock.parked > 1 }, limit: 0.05) == false)
    #expect(clock.durations == [DeviceBrowser.settleWindow])
}

// MARK: - What gets listed

// The fixture carries two instances that are NOT ours on purpose: a filter test
// whose every instance matches never exercises the filter.
@Test @MainActor func onlyAwtrixInstancesAreListed() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())

    browsing.emit(.results([printer, "awtrix_a07f9c", "Living Room"]))

    #expect(subject.state == .listed([DiscoveredDevice(instanceName: "awtrix_a07f9c")]))
}

// A browse that answered with somebody else's printers has not answered the
// question yet — ours may still be a retransmission away. Reporting an empty
// network here is the flash of "no devices" a second before the device appears.
@Test @MainActor func aBrowseCarryingNoneOfOursIsStillSearching() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.results([printer, "Living Room"]))

    #expect(subject.state == .searching)

    clock.elapse()
    #expect(await waitUntil { subject.state == .listed([]) })
}

// The window is a deadline for silence, not a delay on the answer.
@Test @MainActor func aFoundDeviceIsListedWithoutWaitingOutTheWindow() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(subject.state == .listed([DiscoveredDevice(instanceName: "awtrix_a07f9c")]))
    #expect(clock.parked == 1)
}

// Two clocks on the same network is not hypothetical, and neither one is more
// the device than the other. Listing both and picking neither is the only
// honest answer — the address the app talks to is the user's to say.
@Test @MainActor func twoDevicesAreBothListedRatherThanOnePickedForTheUser() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())

    browsing.emit(.results(["awtrix_ff0102", "awtrix_a07f9c"]))

    #expect(subject.state == .listed([
        DiscoveredDevice(instanceName: "awtrix_a07f9c"),
        DiscoveredDevice(instanceName: "awtrix_ff0102"),
    ]))
}

// One clock reached over both Wi-Fi and Ethernet is reported once per
// interface. Two results, one device — a list that counts them separately tells
// the user they have two clocks and invites them to pick the wrong one.
@Test @MainActor func theSameInstanceSeenTwiceIsOneDevice() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())

    browsing.emit(.results(["awtrix_a07f9c", "awtrix_a07f9c"]))

    #expect(subject.state == .listed([DiscoveredDevice(instanceName: "awtrix_a07f9c")]))
}

// mDNS reports in whatever order answers arrive, and the panel is read by a
// person: a list that reshuffles itself on every callback is unreadable.
@Test @MainActor func devicesAreListedInAStableOrder() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())

    browsing.emit(.results(["awtrix_ff0102", "awtrix_000001", "awtrix_a07f9c"]))

    #expect(subject.found.map(\.instanceName) == ["awtrix_000001", "awtrix_a07f9c", "awtrix_ff0102"])
}

@Test @MainActor func aDeviceThatGoesAwayLeavesTheList() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())
    browsing.emit(.results(["awtrix_ff0102", "awtrix_a07f9c"]))

    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(subject.state == .listed([DiscoveredDevice(instanceName: "awtrix_a07f9c")]))
}

// The last one going away is an answered question, not an unanswered one: the
// browse already spoke once, so this is an empty network rather than a search
// still running.
@Test @MainActor func theLastDeviceGoingAwayLeavesAnEmptyNetworkNotASearch() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())
    browsing.emit(.results(["awtrix_a07f9c"]))

    browsing.emit(.results([]))

    #expect(subject.state == .listed([]))
}

// `found` is what the panel lists, and it has to be empty for every state that
// is not a list — a refusal that reported the last known devices would show a
// device the app can no longer see.
@Test @MainActor func nothingIsListedForAnythingThatIsNotAList() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())
    browsing.emit(.results(["awtrix_a07f9c"]))
    #expect(subject.found.count == 1)

    browsing.emit(.denied)
    #expect(subject.found.isEmpty)

    browsing.emit(.failed("boom"))
    #expect(subject.found.isEmpty)
}

// MARK: - Starting and stopping

@Test @MainActor func startingAgainReplacesTheBrowseRatherThanAddingOne() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    subject.start()

    #expect(browsing.starts == 2)
    // The first browse cancelled, not left running. Two live browsers report
    // the same device twice, and `stop` can only cancel the second — the first
    // goes on reporting for the life of the app.
    #expect(browsing.liveBrowses == 1)
}

// A restart asks the question again, so the answer starts out unknown — a
// refusal that survived one would be reported for a browse that never ran.
@Test @MainActor func startingAgainAsksTheQuestionAfresh() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())
    browsing.emit(.denied)

    subject.start()

    #expect(subject.state == .searching)
}

@Test @MainActor func stoppingCancelsTheBrowse() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())

    subject.stop()

    #expect(browsing.liveBrowses == 0)
    #expect(subject.state == .idle)
}

// A stopped browse knows nothing, and saying so is what keeps the panel from
// showing a device the app is no longer looking for. `.idle` rather than the
// list it last had — the evidence for that list was cancelled with the browse.
@Test @MainActor func aStoppedDiscoveryReportsNothingRatherThanItsLastAnswer() async {
    let browsing = FakeBonjourBrowser()
    let subject = await startedBrowser(browsing: browsing, clock: SettleClock())
    browsing.emit(.results(["awtrix_a07f9c"]))
    #expect(subject.found.count == 1)

    subject.stop()

    #expect(subject.state == .idle)
    #expect(subject.found.isEmpty)
}

// The window outlives the browse unless it is cancelled with it, and what it
// does when it lands is overwrite whatever the panel is showing with "nothing
// here" — for a browse that is no longer running.
@Test @MainActor func stoppingAbandonsTheWindowToo() async {
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: FakeBonjourBrowser(), clock: clock)

    subject.stop()

    #expect(await waitUntil { clock.parked == 0 })
    clock.elapse()
    #expect(await waitUntil({ subject.state != .idle }, limit: 0.05) == false)
}

// MARK: - The browser that ships

// The one thing in `NetworkBonjourBrowser` that is not NWBrowser's own: a
// browse reports every endpoint kind, and only a service carries an instance
// name. A host-and-port result mapped by force would crash or name a port.
@Test @MainActor func onlyServiceEndpointsCarryAnInstanceName() {
    #expect(
        NetworkBonjourBrowser.instanceName(
            of: .service(name: "awtrix_a07f9c", type: "_http._tcp", domain: "local.", interface: nil)
        ) == "awtrix_a07f9c"
    )
    #expect(NetworkBonjourBrowser.instanceName(of: .hostPort(host: "10.0.0.5", port: 80)) == nil)
}


// MARK: - What the shipped browser makes of a browser state

// The seam that was missing. `DeviceDiscovery.failure(for:)` maps an `NWError`
// and was well covered; nothing covered the step above it, where an
// `NWBrowser.State` becomes a `BonjourEvent` — and that is where the `.denied`
// decision is actually made for the browser this app ships. Deleting the
// `.waiting`-carries-a-refusal branch used to change no test at all.

@Test @MainActor func aBrowserThatCameUpIsReadyToTheApp() {
    #expect(NetworkBonjourBrowser.event(for: .ready) == .ready)
}

@Test @MainActor func aRefusalThatArrivesAsAFailureIsDenied() {
    let refused = NWBrowser.State.failed(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))

    #expect(NetworkBonjourBrowser.event(for: refused) == .denied)
}

// The rule nobody can confirm against real hardware without revoking the
// machine's permission, and the one the implementation is least sure of: on
// some releases a refusal arrives as `.waiting` rather than `.failed`. It costs
// one constructed state to hold it.
@Test @MainActor func aRefusalThatArrivesAsWaitingIsDeniedToo() {
    let refused = NWBrowser.State.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_NotPermitted)))

    #expect(NetworkBonjourBrowser.event(for: refused) == .denied)
}

// Waiting for a route is not a refusal and not an empty network: it is the
// browse being up and unable to run, which is its own answer.
@Test @MainActor func aBrowseWaitingOnANetworkIsUnavailableRatherThanDeniedOrEmpty() {
    guard case let .unavailable(reason)? = NetworkBonjourBrowser.event(for: .waiting(.posix(.ENETDOWN)))
    else {
        Issue.record("expected unavailable, got \(String(describing: NetworkBonjourBrowser.event(for: .waiting(.posix(.ENETDOWN)))))")
        return
    }
    #expect(reason.contains("Network is down"))
}

@Test @MainActor func aBrowserThatFailedForSomeOtherReasonCarriesIt() {
    let broken = NWBrowser.State.failed(.dns(DNSServiceErrorType(kDNSServiceErr_Unknown)))

    guard case let .failed(reason)? = NetworkBonjourBrowser.event(for: broken) else {
        Issue.record("expected a failure, got \(String(describing: NetworkBonjourBrowser.event(for: broken)))")
        return
    }
    #expect(reason.contains("65537"))
}

// Setting up and being cancelled say nothing about the network, and reporting
// them would move the panel off whatever it is showing for no reason.
@Test @MainActor func aBrowserSettingUpOrCancelledSaysNothing() {
    #expect(NetworkBonjourBrowser.event(for: .setup) == nil)
    #expect(NetworkBonjourBrowser.event(for: .cancelled) == nil)
}

// MARK: - What the shipped browse is built for

// The constant was pinned and its USE was not. Pointing the browse itself at
// `_awtrix._tcp` — a type nothing on earth advertises — left every test green,
// and the panel would then have reported an empty network with confidence.
// This reads the service type back off the browser that `start` builds.
@Test @MainActor func theBrowseIsBuiltForTheServiceTypeTheFirmwareAdvertises() {
    #expect(NetworkBonjourBrowser.serviceType == "_http._tcp")

    let built = String(describing: NetworkBonjourBrowser.makeBrowser().descriptor)

    #expect(built.contains("_http._tcp"))
    #expect(built.contains("bonjour"))
}

// MARK: - A browse that never comes up

// The window is a deadline for SILENCE, and a browse that has not come up is
// not silent about the network — it has not looked at one. Armed in `start()`
// the deadline counted down through "not browsing yet" and then announced that
// nothing was advertising, on a network that did not exist.
@Test @MainActor func aBrowseThatHasNotComeUpOpensNoWindow() async {
    let clock = SettleClock()
    let subject = DeviceBrowser(browsing: { FakeBonjourBrowser() }, sleep: clock.sleep)

    subject.start()

    #expect(subject.state == .searching)
    #expect(await waitUntil({ clock.parked > 0 }, limit: 0.05) == false)
    #expect(clock.durations.isEmpty)
}

@Test @MainActor func aBrowseThatCannotRunSaysSoRatherThanReportingAnEmptyNetwork() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.unavailable("Network is down"))

    #expect(subject.state == .unavailable("Network is down"))
    #expect(subject.state != .listed([]))
}

// And the window goes down with it. A deadline left counting through "no
// network" lands on "nothing on this network", which is the same lie one layer
// deeper.
@Test @MainActor func aBrowseThatCannotRunTakesItsWindowDown() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)

    browsing.emit(.unavailable("Network is down"))

    #expect(await waitUntil { clock.parked == 0 })
    clock.elapse()
    #expect(await waitUntil({ subject.state == .listed([]) }, limit: 0.05) == false)
}

@Test @MainActor func aBrowseThatComesBackUpLooksAgain() async {
    let browsing = FakeBonjourBrowser()
    let clock = SettleClock()
    let subject = await startedBrowser(browsing: browsing, clock: clock)
    browsing.emit(.unavailable("Network is down"))

    browsing.emit(.ready)

    #expect(subject.state == .searching)
    // And a fresh deadline, or the panel says "Looking" for ever.
    #expect(await waitUntil { clock.parked == 1 })
}

// MARK: - Late reports

/// A browser that goes on delivering after it is cancelled.
///
/// `FakeBonjourBrowser` drops its handlers on `cancel()`, which is the polite
/// behaviour and therefore cannot show whether anything guards against the
/// impolite one. Nothing promises `NWBrowser.cancel()` is the last word.
@MainActor
private final class LeakyBonjourBrowser: BonjourBrowsing {
    private var handlers: [@MainActor (BonjourEvent) -> Void] = []

    func start(onEvent: @escaping @MainActor (BonjourEvent) -> Void) { handlers.append(onEvent) }
    func cancel() {}
    /// Delivers to one browse in particular, by the order it was started, so a
    /// test can speak as the browse that was dropped rather than as both.
    func emit(_ event: BonjourEvent, from browse: Int) { handlers[browse](event) }
}

// A device arriving from a browse nobody is running any more would put it back
// on a panel that has stopped looking.
@Test @MainActor func aReportFromAStoppedBrowseIsIgnored() {
    let browsing = LeakyBonjourBrowser()
    let subject = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    subject.start()
    subject.stop()

    browsing.emit(.results(["awtrix_a07f9c"]), from: 0)

    #expect(subject.state == .idle)
    #expect(subject.found.isEmpty)
}

// The same for a browse that has been replaced: the one that was dropped keeps
// its own handler, and its reports are about a question nobody asked twice.
@Test @MainActor func aReportFromAReplacedBrowseIsIgnored() {
    let browsing = LeakyBonjourBrowser()
    let subject = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    subject.start()
    subject.start()

    // Spoken by the browse that was replaced, not by the one now running.
    browsing.emit(.denied, from: 0)

    #expect(subject.state == .searching)
    #expect(subject.state != .denied)
}

// MARK: - What the app browses with when nobody says

// The one thing the app is wired to and no test named: the shipped default.
@Test @MainActor func theShippedDefaultBrowsesWithTheNetworkBrowser() {
    #expect(DeviceBrowser.networkBrowsing() is NetworkBonjourBrowser)
}
