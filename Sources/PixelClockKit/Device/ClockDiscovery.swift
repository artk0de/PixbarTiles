import Combine
import Foundation

/// One clock seen advertising itself, whichever way it said so — the row the
/// Clocks section lists and the thing "Add" acts on.
///
/// The AWTRIX browse reports an mDNS instance name, and the firmware answers
/// to exactly that name under `.local`, so the row's address is the name's. A
/// TC002 broadcast arrives from the device's own address and carries the
/// model in its line. Neither row is a connection: being seen is not being
/// reachable, and the Add action is what probes an address before believing
/// it.
public struct DiscoveredClock: Sendable, Equatable {
    public let name: String
    public let model: String
    public let address: String

    public init(name: String, model: String, address: String) {
        self.name = name
        self.model = model
        self.address = address
    }
}

/// Both models seen on the network, merged: the AWTRIX Bonjour browse and the
/// TC002's UDP 55555 broadcasts answering one question through one list.
///
/// The browse keeps its own state machine — settle windows, refusals, the
/// difference between an empty network and no network — and this type passes
/// its answer through untouched, because the panel's status line reads it.
/// The list is the addition: AWTRIX rows from the browse, TC002 rows from the
/// broadcasts, both carrying an address "Add" can act on.
///
/// The same evidence rule the browse keeps about its own findings holds for
/// the whole list: stopped, nothing here can be seen any more, and a list
/// that outlives its evidence is a lie about the network.
@MainActor
public final class ClockDiscovery: ObservableObject {
    /// Where sightings come from. Named, like `DeviceBrowser.networkBrowsing`,
    /// so no socket exists in a process that never looks — which is every
    /// minute the clock is answering and every test.
    public static let broadcastSightings: @MainActor () -> AsyncStream<UlanziSighting> = {
        UlanziBroadcastListener().announcements()
    }

    /// The browse's own answer, verbatim — the status line's input.
    @Published public private(set) var state: DiscoveryState = .idle
    /// The merged list, both models, deterministic order.
    @Published public private(set) var found: [DiscoveredClock] = []

    public let browse: DeviceBrowser
    private let makeSightings: @MainActor () -> AsyncStream<UlanziSighting>
    /// The sighting consumer, while listening. Cancelling it ends the stream,
    /// which is what takes the socket down.
    private var listening: Task<Void, Never>?
    /// TC002 rows by MAC: one device, one row — a re-sighting is the same
    /// clock saying hello again, possibly from a moved address, not a second
    /// clock.
    private var ulanzi: [String: DiscoveredClock] = [:]
    private var observations: [AnyCancellable] = []

    public init(
        browse: DeviceBrowser,
        sightings: @escaping @MainActor () -> AsyncStream<UlanziSighting> =
            ClockDiscovery.broadcastSightings
    ) {
        self.browse = browse
        self.makeSightings = sightings
        // A nested `ObservableObject` publishes nothing to whoever holds this
        // one, so the state is carried across here and the rows recomputed on
        // every answer.
        observations.append(
            browse.$state.sink { [weak self] answered in
                guard let self else { return }
                self.state = answered
                self.remerge(browsing: answered)
            }
        )
    }

    /// Asks both halves the question, from scratch.
    public func start() {
        browse.start()
        guard listening == nil else { return }
        let sightings = makeSightings()
        listening = Task { [weak self] in
            for await sighting in sightings {
                self?.record(sighting)
            }
        }
    }

    /// Stops both halves and forgets what was seen — the list is what the app
    /// can no longer see, and showing it would be a list outliving its own
    /// evidence. The sighting rows go before the browse is stopped, so the
    /// answer its stop publishes re-merges an already-empty half rather than
    /// drawing the list down in two visible steps.
    public func stop() {
        listening?.cancel()
        listening = nil
        ulanzi = [:]
        remerge(browsing: state)
        browse.stop()
    }

    private func record(_ sighting: UlanziSighting) {
        let line = sighting.announcement
        ulanzi[line.mac] = DiscoveredClock(
            name: "\(line.model) \(line.mac.suffix(4))",
            model: line.model,
            address: sighting.host
        )
        remerge(browsing: state)
    }

    /// The AWTRIX rows come from the answer handed in rather than from
    /// `browse.found`, because `@Published` delivers in `willSet`: read back
    /// off the browse here, the old answer is still what is stored, and the
    /// rows would trail the status line by one browse event. The TC002 rows
    /// live here.
    private func remerge(browsing: DiscoveryState) {
        let browsed: [DiscoveredClock]
        if case let .listed(devices) = browsing {
            // The browse only ever answers with AWTRIX instances —
            // `DeviceDiscovery.isAwtrixInstance` filtered everything else —
            // and this is how the Clocks section names that model.
            browsed = devices.map {
                DiscoveredClock(
                    name: $0.instanceName, model: "AWTRIX 3", address: $0.host
                )
            }
        } else {
            browsed = []
        }
        found = (browsed + ulanzi.values).sorted { $0.address < $1.address }
    }
}
