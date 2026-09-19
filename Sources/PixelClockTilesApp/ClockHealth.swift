// Sources/PixelClockTilesApp/ClockHealth.swift
import Foundation
import PixelClockKit

/// One clock's answer to "are you there", its battery, and where it went.
///
/// What `AppModel` held for its one clock (`monitor`, `unansweredPolls`,
/// `followTheClock`), one instance per clock, so a clock that stops answering
/// is looked for — and counted — on its own.
///
/// `@unchecked` names what the isolation checker cannot see: every mutable
/// field here is `@MainActor`-confined, so the type is as safe as the
/// conformance it refuses to infer.
@MainActor
final class ClockHealth: @unchecked Sendable {
    let clockId: UUID
    private(set) var name: String
    let monitor: DeviceMonitor
    /// The device this health's monitor polls. Held so a relocation can
    /// re-point it, exactly as the model's own device is re-pointed.
    private let device: AwtrixDevice
    private var unansweredPolls = 0
    private let clocks: ClockStore
    private let relocate: AppModel.RelocatingHost?
    /// Told when this clock has moved, so the model can follow with its labels
    /// and a session rebuilt at the new address.
    private let didMove: @MainActor (UUID, String) async -> Void

    init(
        clock: ClockRecord,
        device: AwtrixDevice,
        history: any BatteryHistoryStore,
        relocate: AppModel.RelocatingHost?,
        clocks: ClockStore,
        didMove: @escaping @MainActor (UUID, String) async -> Void
    ) {
        self.clockId = clock.id
        self.name = clock.name
        self.device = device
        self.monitor = DeviceMonitor(device: device, history: history)
        self.relocate = relocate
        self.clocks = clocks
        self.didMove = didMove
    }

    var isOnline: Bool { monitor.isOnline }

    /// One poll: the reading, a crossed threshold if there was one, and the
    /// relocation rule — exactly `AppModel.poll()`'s first and last steps.
    func poll(at now: Date) async -> BatteryWarning? {
        let crossed = await monitor.refresh(at: now)
        await follow()
        return crossed
    }

    /// `AppModel.followTheClock()`'s rule, for this health's clock: the
    /// reading that says the clock is fine also names it, and the failures are
    /// counted until a move is due.
    private func follow() async {
        guard let clock = clocks.all().first(where: { $0.id == clockId }) else { return }
        if case let .online(stats) = monitor.state {
            unansweredPolls = 0
            clocks.update(clock) { $0.hardwareIdentity = stats.uid }
            return
        }
        unansweredPolls += 1
        guard let relocate,
            RelocationSchedule.isDue(afterConsecutiveFailures: unansweredPolls)
        else { return }
        // The count is NOT reset by a successful move, only by a clock that
        // answers: a move onto the wrong address would otherwise reset the
        // rationing and browse again on the very next poll.
        guard let found = await relocate(clock.hardwareIdentity), found != clock.address
        else { return }

        await device.adopt(host: found)
        clocks.update(clock) { $0.address = found }
        await didMove(clockId, found)
    }
}
