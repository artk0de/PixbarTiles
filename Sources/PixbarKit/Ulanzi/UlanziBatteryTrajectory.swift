import Foundation

/// Turns a series of TC002 battery samples into the panel's reading.
///
/// Percent-native, and that is the whole point. The AWTRIX `BatteryTrajectory`
/// is built on the raw ADC — it stores `BatterySample.raw`, maps it through the
/// firmware's `map(raw, 475, 665, 0, 100)`, and INFERS the direction from rise
/// and fall windows. All of that machinery exists because `/api/stats` carries
/// no charging field. The TC002 hands over a firmware-computed percent AND an
/// explicit charging flag, which is strictly better data: the direction is
/// simply read off, with none of the half-hour lag a trend fit costs, and
/// feeding a percent in as a raw would corrupt every threshold and the 0% floor.
///
/// So the only thing fitted here is the discharge rate.
public struct UlanziBatteryTrajectory: Sendable {
    /// How long a discharge must be watched before a rate is put on it.
    ///
    /// Fifteen minutes. The firmware percent is an integer, so a real fall
    /// needs time to show up at all; below this an estimate is two points
    /// wearing a number.
    public static let minimumSpan: TimeInterval = 15 * 60
    /// How long samples are kept. A day, which is the arm a slow discharge
    /// needs before its slope outgrows the quantisation.
    public static let retention: TimeInterval = 24 * 60 * 60

    /// The bottom of the band where the firmware's percent scale stops, and the
    /// cell voltage that goes with a charge that has finished.
    ///
    /// Measured on appVer 1.1.1, 2026-09-23: with the charger's own LED green —
    /// the charge terminated — `BatteryMonitor` read percent 90 at 4174 mV, and
    /// it still read 90 hours later. Every field past the millivolts is zero,
    /// so the firmware carries no "full" flag to copy either. Its scale simply
    /// stops at 90, which means a panel that only repeats the firmware can
    /// never say a charge finished — the one thing a glance at a charging clock
    /// is for.
    ///
    /// Both conditions are required, and that is what keeps this from being a
    /// voltage→percent curve: below the ceiling the firmware's figure is drawn
    /// untouched, and off the charger nothing is corrected at all. It is one
    /// saturation point, not a mapping.
    ///
    /// DO NOT key this on the firmware's exact top figure. The top is a BAND,
    /// not one number: near it the firmware's percent tracks the cell voltage,
    /// and a finished cell resting on the charger sags a few millivolts and
    /// takes the percent down with it. Measured on the live clock 2026-09-24,
    /// charger LED green after a full day on the charger, by a fresh full walk
    /// (new pid, base and monitor pointer — no cache): charging=1, percent=89,
    /// 4167 mV. The 2026-09-23 pair was 90 at 4174 mV — one point per ~7 mV.
    /// With the ceiling at exactly 90 the panel showed "89% · Charging" on a
    /// finished charge, which is the regression this constant fixed.
    ///
    /// 85 is the bottom of that band: 4150 mV, the plateau floor below,
    /// extrapolates to 86–87 at that slope, so any figure the firmware gives a
    /// cell that is still on the plateau clears it — while a percent well below
    /// the top next to a plateau voltage (the firmware disagreeing with the
    /// cell) is still drawn as read. The plateau voltage is what says the
    /// charge finished; the percent floor only says the firmware agrees.
    static let ceilingPercent = 85
    static let fullMillivolts = 4150

    private var samples: [UlanziBatterySample] = []

    public init() {}

    public mutating func accept(_ sample: UlanziBatterySample) {
        samples.append(sample)
        let cutoff = sample.at.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.at < cutoff }
    }

    /// What the panel draws, or nil while nothing has been read.
    public var reading: BatteryReading? {
        guard let latest = samples.last else { return nil }
        let direction: BatteryDirection = latest.charging ? .charging : .discharging
        return BatteryReading(
            percent: latest.percent,
            shownPercent: shown(for: latest),
            direction: direction,
            timeRemaining: direction == .discharging ? estimate(to: latest) : nil
        )
    }

    /// What the panel draws.
    ///
    /// The firmware already smooths, and there is no ADC wander to ratchet
    /// against, so the shown figure is normally the read one. The exception is
    /// a finished charge, where the firmware's scale runs out before the cell
    /// does — see `ceilingPercent`.
    private func shown(for latest: UlanziBatterySample) -> Int {
        let full = latest.charging
            && latest.percent >= Self.ceilingPercent
            && latest.millivolts >= Self.fullMillivolts
        return full ? 100 : latest.percent
    }

    /// Seconds to 0%, from a least-squares fit over the trailing discharging
    /// run — or nil while too little has been watched, or while the run is not
    /// actually falling. A clock sitting level is not four hours from empty.
    private func estimate(to latest: UlanziBatterySample) -> TimeInterval? {
        let run = trailingDischargeRun()
        guard let first = run.first, run.count >= 2 else { return nil }
        guard latest.at.timeIntervalSince(first.at) >= Self.minimumSpan else { return nil }

        let xs = run.map { $0.at.timeIntervalSince(first.at) }
        let ys = run.map { Double($0.percent) }
        let n = Double(run.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let varianceX = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard varianceX > 0 else { return nil }

        // Percent per second; a discharge is negative.
        let slope = covariance / varianceX
        guard slope < 0 else { return nil }
        return Double(latest.percent) / -slope
    }

    /// The samples since the battery was last on a charger — the CURRENT
    /// discharge, uncontaminated by the charge before it. A fit across both
    /// averages a rise and a fall into a gentle nothing, and an estimate of
    /// days.
    private func trailingDischargeRun() -> [UlanziBatterySample] {
        guard let lastCharge = samples.lastIndex(where: { $0.charging }) else { return samples }
        return Array(samples[(lastCharge + 1)...])
    }
}
