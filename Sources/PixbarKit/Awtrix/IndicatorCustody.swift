import Foundation

/// What the AWTRIX adapter needs of a clock's indicator lamps.
///
/// A protocol so the custody below can be posed to something that records
/// instead of to a clock on the desk. `AwtrixDevice` satisfies it as written.
public protocol IndicatorLighting: Sendable {
    func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws
}

extension AwtrixDevice: IndicatorLighting {}

/// What each of an AWTRIX clock's indicator lamps is showing, as far as this
/// app put it there.
///
/// The third kind of custody the AWTRIX adapter keeps, beside the borrowed
/// overlay and the apps in the loop. Lamps live on the clock and outlive the
/// app that lit them, so what matters is what LANDED. Remembering what was
/// asked for would rewrite a lamp that had not moved; remembering a failed
/// write would leave a lamp wrong until the thing it shows next changed, which
/// on a quiet afternoon is never.
///
/// An actor because the things that ask it to show something — a network path
/// change, a Focus switch, the minute poll, a launch — arrive from different
/// places and can overlap. Not on the delivery chain: a lamp is one POST and
/// must not wait behind a playing anecdote.
public actor IndicatorCustody {
    private let lamps: any IndicatorLighting

    /// What each lamp is showing, as far as a successful write can say. A slot
    /// missing from here has never been written or last failed — either way,
    /// this app does not know what that lamp looks like and writes it again.
    private var shown: [IndicatorSlot: IndicatorSignal] = [:]

    public init(lamps: any IndicatorLighting) {
        self.lamps = lamps
    }

    /// Shows `signal` on `slot`, unless that is what the slot already shows.
    public func show(_ signal: IndicatorSignal, on slot: IndicatorSlot) async {
        guard shown[slot] != signal else { return }
        do {
            try await lamps.setIndicator(slot, to: signal)
            shown[slot] = signal
        } catch {
            // Forgotten rather than recorded, so the next trigger writes it
            // again. An unreachable clock is the ordinary case here — the app
            // runs on a laptop and the clock is on a desk it is not always at.
            shown[slot] = nil
        }
    }
}
