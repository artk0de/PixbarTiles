// `ObservableObject` and `@Published` are declared in Combine; Foundation
// re-exports both, so this import names the framework that owns them.
import Combine
import Foundation
import Network

/// One AWTRIX instance seen advertising itself on the local network.
///
/// A name and nothing else, deliberately. The firmware advertises as
/// `awtrix_<mac-suffix>`, and that instance name is not a hostname —
/// `awtrix.local` does not resolve — so there is no address to be had here
/// without resolving the service, and nothing in this type may be mistaken for
/// one. Discovery answers "is there a clock on this network", not "where".
public struct DiscoveredDevice: Sendable, Equatable {
    public let instanceName: String

    public init(instanceName: String) {
        self.instanceName = instanceName
    }
}

/// How far discovery has got, and what it actually knows.
///
/// Five cases rather than a list that may be empty, because an empty list is
/// the answer to three different questions and the user can only act on one of
/// them. "You have not been asked yet", "we are still looking", "nothing is
/// advertising here" and "you refused this app the local network" all render as
/// zero devices, and a panel that says "no devices found" to somebody who
/// declined the permission prompt is telling them the wrong thing to fix.
public enum DiscoveryState: Sendable, Equatable {
    /// Never started, or stopped.
    case idle
    /// Browsing, with nothing yet worth reporting.
    case searching
    /// The browse answered. Empty means nothing on this network is ours — that
    /// is a finding, not a silence.
    case listed([DiscoveredDevice])
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
/// filtering, the settle window, the three answers — is exercised without a
/// network, and what is left here is the framework call itself.
@MainActor
public final class NetworkBonjourBrowser: BonjourBrowsing {
    /// The firmware advertises its web interface, not a service of its own.
    public static let serviceType = "_http._tcp"

    private var browser: NWBrowser?

    public init() {}

    public func start(onEvent: @escaping @MainActor (BonjourEvent) -> Void) {
        cancel()
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil), using: .init()
        )
        browser.stateUpdateHandler = { state in
            // The handler queue below is `.main`, which is where this actor
            // lives; the isolation is real, the compiler simply cannot see it
            // through NWBrowser's non-isolated callback.
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    onEvent(.ready)
                case let .failed(error):
                    onEvent(DeviceDiscovery.failure(for: error))
                case let .waiting(error):
                    // `.waiting` is normally transient — no route yet, and the
                    // browse recovers by itself — so it is not reported as a
                    // failure. A refusal is the exception: it is terminal, and
                    // it arrives here rather than in `.failed` on some
                    // releases.
                    if case .denied = DeviceDiscovery.failure(for: error) { onEvent(.denied) }
                default:
                    break
                }
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

    @Published public private(set) var state: DiscoveryState = .idle

    /// How a browse is obtained, rather than a browse already obtained.
    ///
    /// A factory because `NetworkBonjourBrowser` holds an `NWBrowser?`, and an
    /// instance of that type sitting at rest in a process that also drives an
    /// AppKit run loop deadlocks it: with one held by `AppDelegate` and never
    /// started, sixteen unrelated main-actor tests stopped completing, every
    /// time, at 0% CPU. Bisected to this and nothing else — the same object
    /// behind a browser that names no `Network` type is green. Built when a
    /// browse begins and dropped when it ends, no such object exists in a
    /// process that never browses, which includes every test.
    private let makeBrowsing: @MainActor () -> any BonjourBrowsing
    /// The browse currently running, if one is.
    private var browsing: (any BonjourBrowsing)?
    private let settleWindow: TimeInterval
    private let sleep: Sleeping
    private var settleTask: Task<Void, Never>?
    /// Whether silence now means "nothing here" rather than "not yet".
    private var hasSettled = false

    public init(
        browsing: @escaping @MainActor () -> any BonjourBrowsing = { NetworkBonjourBrowser() },
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
        state = .searching
        let browsing = makeBrowsing()
        self.browsing = browsing
        browsing.start { [weak self] event in self?.handle(event) }
        let sleep = self.sleep
        let window = self.settleWindow
        settleTask = Task { [weak self] in
            // A cancelled window is a stopped browse, and returning here is
            // what keeps it from overwriting the panel afterwards.
            do { try await sleep(window) } catch { return }
            self?.settle()
        }
    }

    /// Stops browsing and abandons the window with it.
    ///
    /// Synchronous, and awaited by nobody: quit already has a budget to spend
    /// on a held banner, and a browse has nothing in flight worth adding to it.
    public func stop() {
        settleTask?.cancel()
        settleTask = nil
        browsing?.cancel()
        browsing = nil
        state = .idle
    }

    private func handle(_ event: BonjourEvent) {
        switch event {
        case .ready:
            // The browse is up. That is not yet an answer about the network.
            break
        case let .results(names):
            report(names)
        case .denied:
            state = .denied
        case let .failed(reason):
            state = .failed(reason)
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
    /// A browse that was refused, failed, or already reported has said
    /// something more specific than "nothing here", and the window must not
    /// overwrite it — a refusal above all, since it produces exactly the
    /// silence this deadline exists to interpret.
    private func settle() {
        hasSettled = true
        guard case .searching = state else { return }
        state = .listed([])
    }
}
