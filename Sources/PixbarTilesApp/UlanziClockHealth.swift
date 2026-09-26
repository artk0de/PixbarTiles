import Foundation
import PixbarKit

/// What a TC002 clock's session hears from the reachability poll — the one
/// steady look the app takes at the clock, and so where a reboot is noticed.
protocol UlanziClockWatching: Sendable {
    /// The clock answers again after the poll found it gone: every page is
    /// owed a sweep.
    func clockReturned() async
    /// An ordinary answering tick: check the clock still lists every page.
    func verifyPages() async
}

extension UlanziClockSession: UlanziClockWatching {}

/// One TC002 clock's answer to "are you there".
///
/// What `ClockHealth` is for an AWTRIX clock, minus everything this firmware
/// does not have: no relocation (the broadcast carries the MAC the store
/// already keeps), and no stats — the only health surface this firmware
/// answers over HTTP is `/getBase`, whose body is an identity and nothing
/// more.
///
/// The battery is the exception, and it does not come over HTTP at all: the
/// stock API reports no level, so it is read out of the `zkgui` process memory
/// over the device's root adb (see `UlanziBattery`). That read is optional and
/// silent — a clock whose firmware is unknown, or which has no adb route,
/// simply carries no battery line. There is nothing here to carry in a
/// `DeviceState.online`, so the answering state is this type's own three
/// cases, said in the words `DeviceStatusLine` uses for every other clock.
///
/// `@unchecked` names what the isolation checker cannot see, exactly as on
/// `ClockHealth`: every mutable field here is `@MainActor`-confined.
@MainActor
final class UlanziClockHealth: @unchecked Sendable {
    enum Answering: Equatable {
        /// No poll has run yet. Not online, and not offline either — an
        /// answer nobody took is not a disconnection.
        case notAsked
        /// `/getBase` answered an identity.
        case answering
        /// The poll asked and nothing usable came back.
        case unreachable
    }

    let clockId: UUID
    let name: String
    private(set) var answering: Answering = .notAsked
    private let device: UlanziDevice
    /// The battery reader, or nil where there is none to have — no adb route,
    /// or a build with no bundled helper. Nil simply means the panel draws no
    /// battery line, exactly as it did before this existed.
    private let battery: UlanziBattery?
    private var trajectory = UlanziBatteryTrajectory()
    /// The clock's session, looked up at each tick rather than held: the
    /// model builds sessions and healths in separate places, and a clock
    /// whose session is gone simply has nobody to tell.
    private let watcher: @MainActor () -> (any UlanziClockWatching)?
    /// The last word passed to the session. Not awaited by the poll — a sweep
    /// is several uploads, and the panel's reading must not wait on them — but
    /// kept so a test can.
    private(set) var watching: Task<Void, Never>?

    /// How long a poll waits for the battery before answering without it.
    private let batteryDeadline: Duration
    /// The battery read in flight, until it comes back — however late.
    private var batteryRead: Task<UlanziBatteryPoll, Never>?

    init(
        clockId: UUID, name: String, device: UlanziDevice, battery: UlanziBattery?,
        batteryDeadline: Duration = .seconds(20),
        watcher: @escaping @MainActor () -> (any UlanziClockWatching)? = { nil }
    ) {
        self.clockId = clockId
        self.name = name
        self.device = device
        self.battery = battery
        self.batteryDeadline = batteryDeadline
        self.watcher = watcher
    }

    var isOnline: Bool { answering == .answering }

    /// The battery as the last successful read left it.
    ///
    /// Not cleared when a poll fails: the panel is the clocks' glance, and a
    /// charge that vanishes every time the Wi-Fi blips is a figure nobody can
    /// plan around.
    private(set) var lastKnownBattery: BatteryReading?

    /// One poll: the clock answered or it did not, and — when the firmware is
    /// one whose battery offset is known — what its cell is doing.
    ///
    /// No threshold to cross and no warning to return: the TC002's warnings
    /// are not wired to this path yet, and inventing one here would fire it
    /// from a reading the rest of the app has never seen.
    ///
    /// Every battery failure is silent by construction — `read` returns nil
    /// rather than throwing — so a clock that answers `/getBase` still counts
    /// as online even when its memory read fails.
    ///
    /// An answering tick also tells the clock's session what it saw: back from
    /// unreachable is a return (the clock may have rebooted, every page owed a
    /// sweep); any other answer is a cue to check the page list.
    func poll(at now: Date) async -> BatteryWarning? {
        let before = answering
        do {
            let identity = try await device.identity()
            answering = .answering
            var restarted = false
            if let battery, let read = await readBattery(battery, appVersion: identity.appVersion, at: now) {
                // A new zkgui process is a firmware UI that restarted without
                // the clock ever going unreachable — its pages are gone too.
                restarted = read.zkguiRestarted
                if let sample = read.sample {
                    trajectory.accept(sample)
                    lastKnownBattery = trajectory.reading
                }
            }
            tellSession(returned: before == .unreachable || restarted)
        } catch {
            answering = .unreachable
        }
        return nil
    }

    /// The battery, if it answers within the deadline; nil when it does not,
    /// or when the last read has not come back yet.
    ///
    /// The model's poll awaits this one, and every clock's reachability, the
    /// menu bar glyph and the battery line hang off that poll — so a read
    /// that never returns must not be awaited. One did: a clock back on the
    /// network before its adbd was listening left the adb connect waiting
    /// for good, and the whole poll with it (2026-09-26). A late read is left
    /// to finish on its own, and no second one is started on top of it.
    private func readBattery(
        _ battery: UlanziBattery, appVersion: String?, at now: Date
    ) async -> UlanziBatteryPoll? {
        guard batteryRead == nil else { return nil }
        let read = Task { @MainActor [weak self] in
            let answer = await battery.poll(appVersion: appVersion, at: now)
            self?.batteryRead = nil
            return answer
        }
        batteryRead = read
        return await Self.value(of: read, within: batteryDeadline)
    }

    /// The task's value, or nil once the deadline passes first.
    private static func value<T: Sendable>(of task: Task<T, Never>, within deadline: Duration) async -> T? {
        await withCheckedContinuation { (answer: CheckedContinuation<T?, Never>) in
            var answered = false
            let timer = Task { @MainActor in
                try? await Task.sleep(for: deadline)
                guard !answered else { return }
                answered = true
                answer.resume(returning: nil)
            }
            Task { @MainActor in
                let value = await task.value
                guard !answered else { return }
                answered = true
                timer.cancel()
                answer.resume(returning: value)
            }
        }
    }

    private func tellSession(returned: Bool) {
        guard let session = watcher() else { return }
        // A check behind a word still being handled adds nothing but a queue:
        // a session stuck on a slow push would collect one per minute.
        if pendingWords > 0, !returned { return }
        let previous = watching
        pendingWords += 1
        // One word at a time, in order: a check must not overtake the return
        // it follows.
        watching = Task {
            await previous?.value
            if returned {
                await session.clockReturned()
            } else {
                await session.verifyPages()
            }
            pendingWords -= 1
        }
    }
    private var pendingWords = 0
}
