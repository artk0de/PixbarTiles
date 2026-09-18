import PixelClockKit
import Foundation

/// What this app needs of the clock's indicator lamps.
///
/// Declared here rather than in the kit for the reason `ConnectorRunning` is:
/// this is the app's view of what it drives, and it exists so the display below
/// can be posed to something that records instead of to a clock on the desk.
/// `AwtrixDevice` satisfies it as written.
protocol IndicatorLighting: Sendable {
    func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws
}

extension AwtrixDevice: IndicatorLighting {}

/// Keeps the clock's two VPN corners in step with this machine.
///
/// An actor because it holds what the lamps are showing, and the things that
/// ask it to show something — a network path change, a Focus switch, the
/// minute poll, a launch — arrive from different places and can overlap.
///
/// It remembers per lamp rather than per reading, and only what actually
/// LANDED. Both halves matter. Remembering the reading would rewrite a corner
/// that had not moved; remembering a failed write would leave a corner wrong
/// until the VPN itself next changed, which on a quiet afternoon is never.
actor VPNLampDisplay {
    private let clock: any IndicatorLighting

    /// What each lamp is showing, as far as a successful write can say. A slot
    /// missing from here has never been written or last failed — either way,
    /// this app does not know what that corner looks like and writes it again.
    private var shown: [IndicatorSlot: IndicatorSignal] = [:]

    init(clock: any IndicatorLighting) {
        self.clock = clock
    }

    func show(_ lamps: VPNLamps) async {
        await write(.topRight, lamps.topRight)
        await write(.bottomRight, lamps.bottomRight)
    }

    /// Puts both corners out, for a quit.
    ///
    /// Indicators live on the clock and outlive the app that set them — the
    /// firmware keeps them through a reconnect and through this process going
    /// away. Without this, quitting while the work tunnel was down would leave
    /// a red corner blinking on somebody's desk with nothing left running that
    /// could ever stop it.
    func clear() async {
        await show(.dark)
    }

    private func write(_ slot: IndicatorSlot, _ signal: IndicatorSignal) async {
        guard shown[slot] != signal else { return }
        do {
            try await clock.setIndicator(slot, to: signal)
            shown[slot] = signal
        } catch {
            // Forgotten rather than recorded, so the next trigger writes it
            // again. An unreachable clock is the ordinary case here — the app
            // runs on a laptop and the clock is on a desk it is not always at.
            shown[slot] = nil
        }
    }
}
