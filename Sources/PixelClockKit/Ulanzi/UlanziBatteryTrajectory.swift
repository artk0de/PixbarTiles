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
            // The firmware already smooths; there is no ADC wander to ratchet
            // against, so the shown figure is the real one.
            shownPercent: latest.percent,
            direction: direction,
            timeRemaining: direction == .discharging ? estimate(to: latest) : nil
        )
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
