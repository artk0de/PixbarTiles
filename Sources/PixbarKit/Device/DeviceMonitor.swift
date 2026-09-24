// `ObservableObject` and `@Published` are declared in Combine. Foundation
// re-exports both as typealiases, so this import is not required to compile —
// it names the framework that actually declares them.
import Combine
import Foundation

public enum DeviceState: Sendable, Equatable {
    case unknown
    case online(DeviceStats)
    case offline(String)
}

/// Publishes device reachability for the menu bar. Owns no timer — the app
/// decides how often to ask, which keeps this testable without real time.
@MainActor
public final class DeviceMonitor: ObservableObject {
    @Published public private(set) var state: DeviceState = .unknown

    private let device: AwtrixDevice
    /// Every reading this monitor has taken, and the verdict they add up to.
    ///
    /// Not `@Published`, deliberately. It moves in lockstep with `state` — the
    /// same refresh writes both — and a second published property would emit a
    /// second `objectWillChange` for one poll, which is the flicker the monitor
    /// already has a test against.
    private var trajectory: BatteryTrajectory
    /// Where the readings are written down, so a relaunch resumes the trend
    /// instead of spending twenty minutes earning it again.
    ///
    /// In memory by default, which is what every test that has no opinion about
    /// persistence wants; the app hands in the durable one. Defaulted rather
    /// than optional because "no store" and "a store that forgets" are the same
    /// behaviour, and one of them is a branch nobody would exercise.
    private let history: any BatteryHistoryStore

    public init(
        device: AwtrixDevice,
        history: any BatteryHistoryStore = InMemoryBatteryHistoryStore()
    ) {
        self.device = device
        self.history = history
        // Resumed at construction rather than on the first poll: the trajectory
        // is a value this object owns from the moment it exists, and a restore
        // deferred to the first refresh would be a second state to be in.
        self.trajectory = BatteryTrajectory(resuming: history.storedHistory())
    }

    /// Asks the clock how it is, and answers with the threshold that reading
    /// just crossed, if any.
    ///
    /// The crossing is returned rather than stored, because it is an edge and
    /// not a state: a property holding "20% was crossed" can be read twice, and
    /// the second read is a second dialog for a crossing that happened once.
    ///
    /// `now` is a parameter for the reason `AnecdoteQueue.reapExpired(now:)`'s
    /// is: the caller supplies the instant. The default is what the app passes,
    /// spelled out at the call site; it is here so that the dozen tests about
    /// reachability, which have no opinion about time, do not have to acquire
    /// one.
    @discardableResult
    public func refresh(at now: Date = Date()) async -> BatteryWarning? {
        do {
            let stats = try await device.stats()
            let warning = trajectory.record(stats, at: now)
            // Written on the way past rather than at quit. The exits that lose
            // a session are the ones with no teardown in them — a force quit, a
            // crash, a logout that outruns the quit budget — and those are
            // exactly the launches somebody reopens wanting to know what the
            // battery is doing.
            if let series = trajectory.history { history.save(series) }
            state = .online(stats)
            return warning
        } catch {
            state = .offline(error.localizedDescription)
            return nil
        }
    }

    public var isOnline: Bool {
        if case .online = state { return true }
        return false
    }

    public var batteryPercent: Int? {
        guard case let .online(stats) = state else { return nil }
        return stats.bat
    }

    /// Where the battery is, which way it is going, and how long that leaves.
    ///
    /// Nil while the clock is not answering, for the reason `batteryPercent` is:
    /// the last thing a device said before it went quiet is not what it is doing
    /// now, and a panel that keeps drawing a battery beside "Disconnected" is
    /// reporting a reading nobody took.
    public var battery: BatteryReading? {
        guard case .online = state else { return nil }
        return trajectory.reading
    }

    /// The last reading the clock gave, whether or not it is answering now —
    /// what a statistics panel shows while a clock is briefly away. A clock
    /// that has never answered has nothing, and that is still the honest nil.
    public var lastKnownBattery: BatteryReading? {
        trajectory.reading
    }
}
