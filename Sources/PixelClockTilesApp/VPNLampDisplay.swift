import Foundation
import PixelClockKit

/// Keeps the clock's two VPN corners in step with this machine.
///
/// The VPN half of the lamps: which two corners, and that a quit darkens both.
/// What each lamp shows, and writing only what moved, is the AWTRIX adapter's
/// `IndicatorCustody`; this asks it one corner at a time.
struct VPNLampDisplay: Sendable {
    private let indicators: IndicatorCustody

    init(indicators: IndicatorCustody) {
        self.indicators = indicators
    }

    func show(_ lamps: VPNLamps) async {
        await indicators.show(lamps.topRight, on: .topRight)
        await indicators.show(lamps.bottomRight, on: .bottomRight)
    }

    /// Puts both corners out, for a quit.
    ///
    /// Indicators live on the clock and outlive the app that set them — the
    /// firmware keeps them through a reconnect and through this process going
    /// away. Without this, quitting while the work tunnel was down would leave
    /// a red corner blinking on somebody's desk with nothing left running that
    /// could ever stop it.
    ///
    /// Both corners always, including one this launch never lit. The clock may
    /// still hold what an earlier run left there.
    func clear() async {
        await show(.dark)
    }
}
