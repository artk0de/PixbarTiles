import Foundation

/// Which way the battery is going, as far as the readings can say.
///
/// Three answers, not two. The firmware reports no charging or mains field —
/// `/api/stats` carries `bat`, `bat_raw`, `uptime`, `uid` and a dozen things
/// about the display, and nothing about power — so being plugged in is inferred
/// from the trend, and "not inferred yet" is a state of its own. A verdict the
/// readings have not reached is the same lie as a confident estimate from two
/// samples.
public enum BatteryDirection: Sendable, Equatable {
    case unknown
    case charging
    case discharging
}

/// What the panel says about the battery: where it is, which way it is going,
/// and how long that leaves.
public struct BatteryReading: Sendable, Equatable {
    public let percent: Int
    public let direction: BatteryDirection
    /// Seconds to empty, or nil while there is not enough observed to say.
    public let timeRemaining: TimeInterval?

    public init(percent: Int, direction: BatteryDirection, timeRemaining: TimeInterval?) {
        self.percent = percent
        self.direction = direction
        self.timeRemaining = timeRemaining
    }
}

/// A threshold the battery has just fallen through, and where it actually is.
///
/// Both, because they are different numbers: a poll a minute apart can find the
/// battery at 19% having last seen it at 25%, and the warning is about the 20%
/// line while the text the user reads is about the 19.
public struct BatteryWarning: Sendable, Equatable {
    public let threshold: Int
    public let percent: Int

    public init(threshold: Int, percent: Int) {
        self.threshold = threshold
        self.percent = percent
    }
}

/// Everything one clock has said about its battery, and what that adds up to.
///
/// A value rather than an object: `DeviceMonitor` owns exactly one, mutates it
/// on every poll and reads it back, and there is nothing here for a second
/// reference to be useful for.
public struct BatteryTrajectory: Sendable {
    /// How far back a rate is measured over.
    ///
    /// Doubles as what counts as a gap: readings this far apart describe two
    /// situations rather than one, because everything between them is
    /// unobserved. Ninety minutes is ninety polls at the shipped cadence.
    public static let window: TimeInterval = 90 * 60
    /// How much has to have been watched before a number is put on it. Below
    /// this, "four hours" means "I have two readings".
    ///
    /// Fifteen minutes, which at the shipped cadence is fifteen samples for the
    /// fit to run through. A rate read off five of them is noise wearing a
    /// number.
    public static let minimumSpan: TimeInterval = 15 * 60
    /// How far the raw reading has to have moved before the same. Two is inside
    /// what an ADC on a battery divider wanders by while nothing happens.
    public static let minimumRawDelta = 4
    /// What a derived raw-steps-per-percent may be, before it is refused as
    /// something the readings cannot have meant.
    ///
    /// The firmware's map is undocumented and this is not an attempt to guess
    /// it — the slope is fitted per window, which is the whole point. The band
    /// is only a sanity check on the fit, and it is wide: the clock on this
    /// desk answers 665 raw at 100% and 648 at 91%, about two steps to the
    /// percent, and another divider could plausibly spend ten times that.
    ///
    /// What it refuses is a fit that cannot be a map at all. A window straddling
    /// the firmware's own cap — `bat` pinned at 100 while the raw figure falls,
    /// then one step to 99 — fits a slope several times the real one, and an
    /// estimate divided by that is wrong by the same factor. Anything outside
    /// the band falls back to the percentage rather than being scaled by a
    /// number nobody can defend.
    public static let rawPerPercentBand: ClosedRange<Double> = 1...20
    /// Where a warning fires, in percent. Ordered high to low, and read as a
    /// set rather than in order — a poll can find the battery below several at
    /// once.
    public static let thresholds = [20, 10, 5, 1]
    /// How far back over a threshold the battery has to climb before that
    /// threshold can fire again.
    ///
    /// Without it, a battery hovering either side of 20% warns on every wobble
    /// — the same storm the edge trigger exists to stop, arriving more slowly.
    public static let rearmMargin = 3

    /// One reading, with the instant it was taken at.
    private struct Sample {
        let raw: Int
        let percent: Int
        let at: Date
    }

    /// Readings inside the window, oldest first. Only ones carrying a raw
    /// figure: a firmware that omits it contributes a percentage and no trend.
    private var samples: [Sample] = []
    /// The whole of the last report, which is what `uid` and `uptime` are read
    /// off — and what the percentage is read off, so that a clock with no raw
    /// figure still has one.
    private var latest: DeviceStats?
    private var direction: BatteryDirection = .unknown
    /// Thresholds that may still fire. Everything to begin with: a first poll
    /// finding the battery already at 4% has news, and it is only the direction
    /// gate that holds it back until there is a trend to gate on.
    private var armed: Set<Int> = Set(BatteryTrajectory.thresholds)

    public init() {}

    /// Takes one reading, and answers with the threshold it just fell through.
    ///
    /// The crossing comes back as a return value rather than being stored,
    /// because it is an edge and not a state: a property holding "20% was
    /// crossed" can be read twice, and the second read is a second dialog for
    /// something that happened once.
    ///
    /// `now` is the caller's, on the same argument as
    /// `AnecdoteQueue.reapExpired(now:)`: a clock abstraction would buy a seam
    /// only tests use, where a parameter does the same thing in a signature the
    /// reader can see through.
    @discardableResult
    public mutating func record(_ stats: DeviceStats, at now: Date) -> BatteryWarning? {
        if invalidates(stats, at: now) { discardHistory() }
        latest = stats
        if let raw = stats.batRaw {
            samples.append(Sample(raw: raw, percent: stats.bat, at: now))
            samples.removeAll { now.timeIntervalSince($0.at) > Self.window }
            direction = Self.direction(closing: samples, holding: direction)
        }
        return crossing(at: stats.bat)
    }

    /// Where the battery is, which way it is going, and how long that leaves.
    ///
    /// Nil only before anything has been recorded. Once a clock has answered
    /// once there is always a percentage to show, whatever the trend does or
    /// does not say.
    public var reading: BatteryReading? {
        guard let latest else { return nil }
        return BatteryReading(
            percent: latest.bat, direction: direction, timeRemaining: timeRemaining
        )
    }

    // MARK: - What the readings add up to

    /// Charging, discharging, or whatever it was.
    ///
    /// The last two readings, not the ends of the window. Over an hour and a
    /// half the endpoints describe NET movement, and a clock plugged in five
    /// minutes ago would keep reading as discharging for another eighty-five —
    /// where the raw figure moves several steps to the percent, so the pair is
    /// already enough to be responsive.
    ///
    /// Equal readings hold the previous verdict rather than clearing it: a raw
    /// figure that does not move between two polls is the ordinary case at
    /// rest, and answering "unknown" to it would blank the glyph every few
    /// seconds.
    private static func direction(
        closing samples: [Sample], holding previous: BatteryDirection
    ) -> BatteryDirection {
        guard samples.count >= 2 else { return previous }
        let latest = samples[samples.count - 1].raw
        let before = samples[samples.count - 2].raw
        if latest > before { return .charging }
        if latest < before { return .discharging }
        return previous
    }

    /// Seconds to empty, or nil while there is not enough observed to say.
    ///
    /// Percent over the rate the window actually showed, and every gate below is
    /// a different way of not having a rate.
    ///
    /// The rate is read off the RAW figure and converted, rather than off `bat`
    /// directly. An integer percentage over a window where one percent moved
    /// quantises the rate to plus or minus the whole of it, and the panel
    /// renders that as an hour that is not there. The raw figure is already
    /// collected and moves several steps per percent, so it can say where inside
    /// that percent the battery is — which is the difference between "one
    /// percent went" and "one and seven eighths went".
    private var timeRemaining: TimeInterval? {
        guard direction == .discharging else { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minimumSpan else { return nil }
        guard first.raw - last.raw >= Self.minimumRawDelta else { return nil }
        guard let spending = percentPerSecond(from: first, to: last, over: span) else {
            return nil
        }
        // Zero is the percentage sitting still with nothing to convert it from,
        // and negative cannot reach here past the direction gate. Either renders
        // as "forever".
        guard spending > 0 else { return nil }
        return Double(last.percent) / spending
    }

    /// How fast the battery is being spent, in percent per second.
    ///
    /// Two raw fits divided by each other: how fast the raw figure falls, and
    /// how many raw steps the firmware spends on a percent. The second is what
    /// makes the first mean anything, and it is DERIVED rather than declared —
    /// the map is undocumented, differs by hardware revision, and a constant
    /// here would be a guess baked into every estimate the app ever shows.
    ///
    /// Falls back to the percentage's own endpoints when the window cannot say
    /// what a percent is worth: one distinct percentage in it, or a slope the
    /// band refuses. Coarse, and it is the early window where exactly one
    /// percent has moved — which is precisely when withholding the estimate
    /// altogether is least useful to whoever opened the panel.
    private func percentPerSecond(
        from first: Sample, to last: Sample, over span: TimeInterval
    ) -> Double? {
        if let falling = rateRawPerSecond, let perPercent = rawPerPercent {
            return falling / perPercent
        }
        return Double(first.percent - last.percent) / span
    }

    /// How fast the raw figure is falling, in raw steps per second.
    ///
    /// Fitted over every sample in the window rather than measured between its
    /// ends. Two endpoints are two readings — and two readings, one of which
    /// caught the ADC on a wobble, is the noisiest possible way to use ninety
    /// of them.
    ///
    /// Sign flipped, so that discharging counts up: everything downstream is
    /// about what is being SPENT, and a rate that is negative when the battery
    /// is draining would put the minus sign in every expression that touches it.
    private var rateRawPerSecond: Double? {
        guard let start = samples.first?.at else { return nil }
        // Seconds since the first sample rather than since 1970. The fit squares
        // its x-deviations, and a billion-and-a-half squared spends the
        // precision on the epoch instead of on the window.
        let slope = Self.slope(
            of: samples.map { (x: $0.at.timeIntervalSince(start), y: Double($0.raw)) }
        )
        return slope.map { -$0 }
    }

    /// How many raw steps this clock's firmware spends on one percent, or nil
    /// when this window cannot say.
    ///
    /// Nil on one distinct percentage — a fit needs two x values to have a
    /// slope, and a window where `bat` never moved has nothing to calibrate
    /// against — and nil again when the answer lands outside
    /// `rawPerPercentBand`, which is the fit reporting something that cannot be
    /// a map.
    private var rawPerPercent: Double? {
        guard
            let slope = Self.slope(
                of: samples.map { (x: Double($0.percent), y: Double($0.raw)) }
            )
        else { return nil }
        guard Self.rawPerPercentBand.contains(slope) else { return nil }
        return slope
    }

    /// The slope of a least-squares fit of `y` against `x`, or nil when every
    /// `x` is the same and there is no line to fit.
    ///
    /// Only the slope. An intercept would be the raw figure the fit thinks an
    /// empty battery reads, and nothing here asks that question — the estimate
    /// is a rate over a rate.
    private static func slope(of points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var covariance = 0.0
        var spread = 0.0
        for point in points {
            let dx = point.x - meanX
            covariance += dx * (point.y - meanY)
            spread += dx * dx
        }
        guard spread > 0 else { return nil }
        return covariance / spread
    }

    // MARK: - What discards the history

    /// Whether this reading describes a different situation from the last one.
    ///
    /// Three ways it can, and each of them would otherwise poison the rate with
    /// a pair of readings that never belonged in the same series.
    private func invalidates(_ stats: DeviceStats, at now: Date) -> Bool {
        guard let latest else { return false }
        // A different clock entirely: the address was repointed, or two of them
        // answer on it in turn.
        if stats.uid != latest.uid { return true }
        // Uptime going backwards is a reboot, and a reboot is exactly when
        // somebody unplugged the clock and plugged it in again.
        if let now = stats.uptime, let before = latest.uptime, now < before { return true }
        // The Mac slept, or the app was quit. Equal is not a gap, so a poll
        // that ran exactly on the boundary is kept.
        guard let last = samples.last else { return false }
        return now.timeIntervalSince(last.at) > Self.window
    }

    /// Forgets the readings AND the verdict they produced.
    ///
    /// Both, because a held direction outlives the samples it was derived from:
    /// dropping the readings alone would leave the first poll after a reboot
    /// still claiming the trend from before it.
    ///
    /// What survives is which thresholds are armed. A reboot does not un-tell
    /// the user what they were already told, and the re-arming rule is a
    /// function of the percentage rather than of the history — so a battery
    /// that charged while the app was asleep re-arms on the first reading after
    /// it, with no trend needed.
    private mutating func discardHistory() {
        samples = []
        direction = .unknown
    }

    // MARK: - Warnings

    /// Re-arms what the battery has climbed clear of, and fires what it has
    /// just fallen through.
    ///
    /// In that order, and both halves are deliberate about what they skip.
    /// Re-arming runs whatever the direction is, because it is about where the
    /// battery is rather than where it is going. Firing runs only while
    /// discharging — and, crucially, so does the DISARMING: a clock charging up
    /// through 4% must neither warn nor spend the crossing, or the discharge
    /// that follows would pass the same threshold in silence.
    private mutating func crossing(at percent: Int) -> BatteryWarning? {
        for threshold in Self.thresholds where percent >= threshold + Self.rearmMargin {
            armed.insert(threshold)
        }
        guard direction == .discharging else { return nil }
        let crossed = Self.thresholds.filter { percent <= $0 && armed.contains($0) }
        // The lowest, not the first. A poll can find the battery a long way
        // below where it left it — the Mac slept, or the clock was off the
        // network for an hour — and three dialogs at once is not three times
        // the information. The ones it fell past go with it rather than
        // queueing up to fire on the next poll.
        guard let fired = crossed.min() else { return nil }
        armed.subtract(crossed)
        return BatteryWarning(threshold: fired, percent: percent)
    }
}
