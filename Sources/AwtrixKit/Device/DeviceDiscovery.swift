// `ObservableObject` and `@Published` are declared in Combine; Foundation
// re-exports both, so this import names the framework that owns them.
import Combine
import Foundation
import Network

/// One AWTRIX instance seen advertising itself on the local network.
///
/// The firmware advertises as `awtrix_<mac-suffix>`, and this type used to
/// carry that name and refuse to carry anything else, on the stated grounds
/// that an instance name is not a hostname and so a browse could not know an
/// address. The premise was wrong, and it cost the app a defect: `awtrix.local`
/// indeed does not resolve, but the instance name is not `awtrix` — it is
/// `awtrix_a07f9c`, and the firmware answers to exactly that under `.local`.
/// Measured against the clock on the desk, `awtrix_a07f9c.local` resolved to
/// 192.168.1.67 and served `/api/stats`, through `URLSession` and the
/// underscore included.
///
/// So a browse does answer "where" as well as "whether", and the address it
/// answers with is better than the one a person types: a DHCP lease moves, and
/// a name does not.
public struct DiscoveredDevice: Sendable, Equatable {
    public let instanceName: String

    public init(instanceName: String) {
        self.instanceName = instanceName
    }

    /// The host this clock answers on.
    ///
    /// A construction rather than something the browse reported, which is why
    /// nothing acts on it before `DeviceAdoption.isTheSameClock` has heard the
    /// address say its own name back.
    public var host: String { "\(instanceName).local" }
}

/// How far discovery has got, and what it actually knows.
///
/// Six cases rather than a list that may be empty, because an empty list is the
/// answer to five different questions and the user can only act on some of
/// them. "You have not been asked yet", "we are still looking", "nothing is
/// advertising here", "there is no network to look on" and "you refused this
/// app the local network" all render as zero devices, and a panel that says "no
/// devices found" to somebody who declined the permission prompt — or to
/// somebody whose Wi-Fi is off — is telling them the wrong thing to fix.
public enum DiscoveryState: Sendable, Equatable {
    /// Never started, or stopped.
    case idle
    /// Browsing, with nothing yet worth reporting.
    case searching
    /// The browse answered. Empty means nothing on this network is ours — that
    /// is a finding, not a silence.
    case listed([DiscoveredDevice])
    /// The browse is up but cannot run: no route, an interface down, a link the
    /// system will not browse on. Distinct from an empty network, because there
    /// is no network here to be empty.
    case unavailable(String)
    /// Local Network access refused. Nothing will ever be found until that
    /// changes, and no amount of waiting is the fix.
    case denied
    /// The browse failed for some other reason, in the system's own words.
    case failed(String)
}

/// What a Bonjour browse reports.
///
/// Named here rather than passing `NWBrowser.State` around, so that every case
/// — a refusal above all — can be produced by a test without a network, a
/// device on the LAN, or the machine's Local Network permission revoked.
public enum BonjourEvent: Sendable, Equatable {
    case ready
    /// Instance names exactly as advertised, ours and everybody else's.
    case results([String])
    /// The browse cannot run right now, in the system's own words.
    case unavailable(String)
    case denied
    case failed(String)
}

/// The browsing itself, as the one seam a test replaces.
@MainActor
public protocol BonjourBrowsing {
    func start(onEvent: @escaping @MainActor (BonjourEvent) -> Void)
    func cancel()
}

public enum DeviceDiscovery {
    /// Firmware advertises `_http._tcp` as `awtrix_<mac-suffix>`.
    ///
    /// A prefix AND a suffix: `awtrix_` on its own carries no MAC and is not an
    /// instance of the firmware, while a bare `hasPrefix` would accept it. Case
    /// is ignored because the instance name is whatever the firmware was
    /// flashed with, and the one on the desk answers to either.
    public static func isAwtrixInstance(_ name: String) -> Bool {
        let prefix = "awtrix_"
        let lowered = name.lowercased()
        return lowered.hasPrefix(prefix) && lowered.count > prefix.count
    }

    /// What a browser error means to somebody looking at the panel.
    ///
    /// The two DNS codes are the whole reason this function exists.
    /// `kDNSServiceErr_PolicyDenied` (-65570) is the user having answered no to
    /// the Local Network prompt; `kDNSServiceErr_NotPermitted` (-65571) is a
    /// policy that never asked them. Both produce exactly the silence an empty
    /// network produces, and both are fixed in System Settings rather than by
    /// plugging the clock in — so they are reported as their own state and not
    /// folded into a result set.
    static func failure(for error: NWError) -> BonjourEvent {
        if case let .dns(code) = error {
            let refusals: [DNSServiceErrorType] = [
                DNSServiceErrorType(kDNSServiceErr_PolicyDenied),
                DNSServiceErrorType(kDNSServiceErr_NotPermitted),
            ]
            if refusals.contains(code) { return .denied }
        }
        return .failed(error.debugDescription)
    }
}

/// The `NWBrowser` this app actually ships.
///
/// Its own type, behind `BonjourBrowsing`, so that everything above it — the
/// filtering, the settle window, the answers — is exercised without a network,
/// and what is left here is the framework call itself.
@MainActor
public final class NetworkBonjourBrowser: BonjourBrowsing {
    /// The firmware advertises its web interface, not a service of its own.
    public static let serviceType = "_http._tcp"

    /// The browse this type performs, as one value.
    ///
    /// Hoisted so the service type above and the browse below are one
    /// expression rather than two that can drift apart.
    static let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)

    private var browser: NWBrowser?

    public init() {}

    /// What a browser state means to the app, or nothing when it means nothing.
    ///
    /// Extracted from the handler below because this is where the `.denied`
    /// decision is actually made for the shipped browser, and it is testable
    /// today: `NWBrowser.State` takes a constructed `NWError`, refusal codes
    /// included, with no network and no permission change. Left inline, the
    /// rule that a refusal can arrive in `.waiting` — the one rule here nobody
    /// can confirm against real hardware — had no coverage at all, and deleting
    /// it changed no test.
    static func event(for state: NWBrowser.State) -> BonjourEvent? {
        switch state {
        case .ready:
            .ready
        case let .failed(error):
            DeviceDiscovery.failure(for: error)
        case let .waiting(error):
            // `.waiting` is the browse being up and unable to run — no route,
            // an interface down. Often transient, so it is not a failure; but
            // it is not silence about the network either, which is what it used
            // to be folded into. A refusal is the exception: terminal, and it
            // arrives here rather than in `.failed` on some releases.
            DeviceDiscovery.failure(for: error) == .denied
                ? .denied
                : .unavailable(error.debugDescription)
        default:
            // `.setup` and `.cancelled` say nothing about the network.
            nil
        }
    }

    /// The browser this type starts, built and not started.
    ///
    /// Split out so a test can read back what the browse is actually built
    /// with. `NWBrowser.Descriptor` is not `Equatable`, but `NWBrowser` carries
    /// its own `descriptor` and it renders the service type, so this is
    /// checkable — and constructing an `NWBrowser` reaches nothing, only
    /// `start(queue:)` browses. Before this split the constant was pinned and
    /// its USE was not: pointing the browse at `_awtrix._tcp`, which nothing on
    /// earth advertises, left all 351 tests green while the panel would have
    /// reported an empty network with confidence.
    static func makeBrowser() -> NWBrowser {
        NWBrowser(for: descriptor, using: .init())
    }

    public func start(onEvent: @escaping @MainActor (BonjourEvent) -> Void) {
        cancel()
        let browser = Self.makeBrowser()
        browser.stateUpdateHandler = { state in
            // The handler queue below is `.main`, which is where this type
            // lives; the isolation is real, the compiler simply cannot see it
            // through NWBrowser's non-isolated callback.
            MainActor.assumeIsolated {
                if let event = Self.event(for: state) { onEvent(event) }
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                onEvent(.results(results.compactMap(Self.instanceName)))
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func cancel() {
        browser?.cancel()
        browser = nil
    }

    /// The advertised instance name, when the endpoint has one.
    ///
    /// A browse reports every endpoint kind the transport can name, and only a
    /// service carries an instance name — a host-and-port result has an address
    /// and a number, which is not what is being matched against.
    static func instanceName(of endpoint: NWEndpoint) -> String? {
        guard case let .service(name, _, _, _) = endpoint else { return nil }
        return name
    }

    static func instanceName(of result: NWBrowser.Result) -> String? {
        instanceName(of: result.endpoint)
    }
}

/// Which AWTRIX clocks are advertising themselves, and whether that question
/// has been answered at all.
@MainActor
public final class DeviceBrowser: ObservableObject {
    /// Injected so the window below can be run out by a test without waiting.
    /// The shipped value is the only one that sleeps.
    public typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    /// How long silence is given before it is reported as an empty network.
    ///
    /// mDNS has no "that is all": measured against the real stack, a browse for
    /// a service type nobody advertises goes `.ready` and then never calls back
    /// again, while the clock on the desk was reported 6-14 ms after `.ready`
    /// off a warm cache. Since silence is the same shape either way, a deadline
    /// is the only thing that can turn it into an answer. Three seconds covers
    /// mDNS's own retransmission schedule — the first two retries land at one
    /// and two seconds — with margin for a device that has just joined; the
    /// only cost of being generous is how long the panel says "Looking".
    public static let settleWindow: TimeInterval = 3

    /// How the shipped app obtains a browse.
    ///
    /// Named rather than written inline as a default argument so that a test
    /// can check what the shipped default actually builds without starting it.
    public static let networkBrowsing: @MainActor () -> any BonjourBrowsing = {
        NetworkBonjourBrowser()
    }

    @Published public private(set) var state: DiscoveryState = .idle

    /// How a browse is obtained, rather than a browse already obtained.
    ///
    /// A factory so that no `NWBrowser` holder exists in a process that never
    /// browses — which is every test, and every minute the app spends not
    /// looking. It is dead weight otherwise, and keeping the real `Network`
    /// stack out of code that did not ask for it is worth doing on its own.
    ///
    /// Historical note, and it is an observation rather than a diagnosis:
    /// during this task (2026-08-17, Swift 6.3.3 / macOS 26.6.1) a
    /// `NetworkBonjourBrowser` held at rest by `AppDelegate` coincided with
    /// sixteen unrelated main-actor tests failing to complete, repeatably, at
    /// 0% CPU, and moving to this factory coincided with the suite going green.
    /// Review could not reproduce that in three separate reconstructions, so
    /// the cause is unknown and this factory should not be assumed to be the
    /// remedy for anything like it. Other candidates from the same session —
    /// orphaned test-helper processes thrashing swap, and main-actor busy loops
    /// from instant test clocks — were never ruled out. Diagnose before
    /// reaching for this shape again.
    private let makeBrowsing: @MainActor () -> any BonjourBrowsing
    /// The browse currently running, if one is.
    private var browsing: (any BonjourBrowsing)?
    private let settleWindow: TimeInterval
    private let sleep: Sleeping
    private var settleTask: Task<Void, Never>?
    /// Whether silence now means "nothing here" rather than "not yet".
    private var hasSettled = false
    /// Whether the deadline for this browse has been opened.
    private var windowArmed = false
    /// Which browse the events arriving belong to.
    ///
    /// A browse that has been stopped or replaced may still deliver: nothing
    /// promises that `cancel()` is the last word, and a late callback from a
    /// browse nobody is running would put devices back on a panel that has
    /// stopped looking for them.
    private var generation = 0

    public init(
        browsing: @escaping @MainActor () -> any BonjourBrowsing = DeviceBrowser.networkBrowsing,
        settleWindow: TimeInterval = DeviceBrowser.settleWindow,
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.makeBrowsing = browsing
        self.settleWindow = settleWindow
        self.sleep = sleep
    }

    /// Every AWTRIX instance seen, and nothing for any state that is not a
    /// list.
    ///
    /// A refusal or a failure reports nothing rather than the last devices it
    /// knew about: those are what the app can no longer see, and showing them
    /// is a list that outlives its own evidence.
    public var found: [DiscoveredDevice] {
        guard case let .listed(devices) = state else { return [] }
        return devices
    }

    /// Asks the question, from scratch.
    ///
    /// The previous browse is cancelled first: two live browsers report the
    /// same device twice and `stop` can only cancel the one it is holding.
    public func start() {
        stop()
        hasSettled = false
        windowArmed = false
        state = .searching
        let generation = self.generation
        let browsing = makeBrowsing()
        self.browsing = browsing
        browsing.start { [weak self] event in self?.handle(event, from: generation) }
    }

    /// Stops browsing and abandons the window with it.
    ///
    /// Synchronous, and awaited by nobody: quit already has a budget to spend
    /// on a held banner, and a browse has nothing in flight worth adding to it.
    public func stop() {
        generation += 1
        settleTask?.cancel()
        settleTask = nil
        windowArmed = false
        browsing?.cancel()
        browsing = nil
        state = .idle
    }

    private func handle(_ event: BonjourEvent, from generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .ready:
            armWindow()
        case let .results(names):
            report(names)
        case let .unavailable(reason):
            // The browse cannot run, so nothing it has not said is evidence
            // about anything. The window is taken down with it: a deadline
            // counting through "no network" would land on "nothing on this
            // network", which is a claim about a network nobody looked at.
            settleTask?.cancel()
            settleTask = nil
            windowArmed = false
            hasSettled = false
            state = .unavailable(reason)
        case .denied:
            state = .denied
        case let .failed(reason):
            state = .failed(reason)
        }
    }

    /// Opens the deadline that turns silence into an answer.
    ///
    /// Armed when the browse says it is up, never when it is merely asked to
    /// start. A window opened in `start()` counts down through "not browsing
    /// yet" and then reports an empty network — so with Wi-Fi off the panel
    /// announced that nothing was advertising on a network that did not exist.
    private func armWindow() {
        if case .unavailable = state { state = .searching }
        guard !windowArmed else { return }
        windowArmed = true
        let sleep = self.sleep
        let window = self.settleWindow
        settleTask = Task { [weak self] in
            // A cancelled window is a stopped or interrupted browse, and
            // returning here is what keeps it from overwriting the panel
            // afterwards.
            do { try await sleep(window) } catch { return }
            self?.settle()
        }
    }

    private func report(_ names: [String]) {
        let devices = Set(names.filter(DeviceDiscovery.isAwtrixInstance))
            .sorted()
            .map(DiscoveredDevice.init(instanceName:))
        // A hit is its own deadline: there is something to show, and waiting
        // out the rest of the window would only delay showing it.
        if !devices.isEmpty { hasSettled = true }
        // A browse carrying only somebody else's printers has not answered the
        // question — ours may be one retransmission away — so it stays a search
        // until the window says otherwise. Reporting an empty network here is
        // the flash of "no devices" a second before the device appears.
        guard hasSettled else { return }
        state = .listed(devices)
    }

    /// Turns silence into an answer, and only silence.
    ///
    /// A browse that was refused, failed, went unavailable, or already reported
    /// has said something more specific than "nothing here", and the window
    /// must not overwrite it — a refusal above all, since it produces exactly
    /// the silence this deadline exists to interpret.
    private func settle() {
        hasSettled = true
        guard case .searching = state else { return }
        state = .listed([])
    }
}
