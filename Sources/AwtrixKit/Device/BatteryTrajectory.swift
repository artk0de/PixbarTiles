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
    /// What the clock actually reported. Everything that DECIDES anything reads
    /// this one — the warnings, the colour, the glyph's low line — because a
    /// threshold read off a held figure is a warning that never arrives.
    public let percent: Int
    /// What the panel prints: the same figure, ratcheted to the direction of
    /// travel so that the ADC's own wander does not walk it up and down on
    /// screen while the battery sits still.
    public let shownPercent: Int
    public let direction: BatteryDirection
    /// Seconds to empty, or nil while there is not enough observed to say.
    public let timeRemaining: TimeInterval?

    public init(
        percent: Int, shownPercent: Int, direction: BatteryDirection,
        timeRemaining: TimeInterval?
    ) {
        self.percent = percent
        self.shownPercent = shownPercent
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
    /// How far back the DIRECTION is read over, as against the rate.
    ///
    /// A tenth of the window, and separate from it because the two answer
    /// different questions. The rate wants every sample it can get; the
    /// direction wants to notice a charger being plugged in. Fitted across the
    /// whole ninety minutes, a clock plugged in now would go on reading as
    /// discharging for most of an hour — the shape of the reported defect
    /// again, arriving more slowly.
    public static let trendWindow: TimeInterval = 10 * 60
    /// How much of that has to have been watched before there is a verdict at
    /// all.
    ///
    /// A flat window means "settled on the charger's float" and "nothing has
    /// been watched yet" equally well, and two minutes is where the second
    /// stops being the likely one. `.unknown` stays a real state until then: a
    /// verdict the readings cannot support is worse than none.
    public static let minimumTrendSpan: TimeInterval = 2 * 60
    /// How far the fitted trend has to carry the raw figure across
    /// `trendWindow` before it counts as a fall rather than as the reading
    /// wandering.
    ///
    /// Three raw steps, sized against the clock at rest. Settled on the float
    /// it answers between 667 and 669, and the line fitted through twenty of
    /// those readings drifts under two steps DOWNWARD — so a rule reading any
    /// fall as a discharge calls a clock on mains a discharge, which is the
    /// reported defect. A real discharge spends about ten steps across a
    /// `trendWindow`, an order of magnitude clear of that wander; three sits
    /// between the two and is past inside five readings.
    ///
    /// Applied to the fit and not to consecutive samples, which is what it
    /// replaces. The same clock, charging, answered 665 665 664 664 666 667 668
    /// 669 — four changes of direction across four minutes, every one of them
    /// on screen.
    public static let steadyBand = 3
    /// What the raw figure reads at 0%.
    ///
    /// The firmware's own map, `map(raw, 475, 665, 0, 100)`, which reproduces
    /// both live observations exactly: 648 reads 91 and 665 reads 100. That is
    /// two points fitting a two-parameter line, so this is CONSISTENT with the
    /// readings rather than proven by them, and it is hardcoded on that
    /// understanding.
    ///
    /// The alternative was the intercept of the raw-against-percent fit, which
    /// would calibrate itself per clock. Rejected because it is an
    /// extrapolation ninety percent beyond its own data: a window seeing two
    /// distinct percentages fixes the intercept off a two-percent lever arm,
    /// and the steps the reading wanders by arrive on the answer multiplied by
    /// the same factor. It is also undefined exactly where the percentage is
    /// pinned.
    public static let rawAtEmpty = 475
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
    ///
    /// The raw figure and nothing else. `bat` used to be carried here too, to
    /// derive how many raw steps the firmware spends on a percent; the estimate
    /// is raw-native now and nothing in the fit has a use for a percentage.
    private struct Sample {
        let raw: Int
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
    /// The ratcheted figure, or nil before anything has been recorded.
    private var shown: Int?
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
        // Held across the recompute, because the ratchet is released by a CHANGE
        // of direction and there is nowhere else to see one from.
        let before = direction
        if let raw = stats.batRaw {
            samples.append(Sample(raw: raw, at: now))
            samples.removeAll { now.timeIntervalSince($0.at) > Self.window }
            direction = Self.direction(of: samples, holding: direction)
        }
        ratchet(to: stats.bat, wasGoing: before)
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
            percent: latest.bat, shownPercent: shown ?? latest.bat, direction: direction,
            timeRemaining: timeRemaining
        )
    }

    /// Holds the DISPLAYED percentage to the direction of travel.
    ///
    /// `bat` flickers on the same wander the raw figure carries — the clock on
    /// this desk reported 100, 99, 100 with nothing changing behind it — and a
    /// menu bar figure that walks up and down on its own reads as the app being
    /// wrong rather than as the battery being still.
    ///
    /// The displayed one only. `percent` stays whatever the clock said, and the
    /// warnings, the colour, the glyph and the estimate all read that: a
    /// threshold fired off a ratcheted figure would miss a battery falling
    /// through 20% while the ratchet held it above.
    ///
    /// A CHANGE of direction releases it to the current reading, in either
    /// direction. Without that, a clock unplugged at 100 would be pinned there
    /// for the whole of the discharge that follows, which is worse than the
    /// flicker this exists to stop.
    private mutating func ratchet(to percent: Int, wasGoing previous: BatteryDirection) {
        guard direction == previous, let held = shown else {
            shown = percent
            return
        }
        switch direction {
        case .charging: shown = max(held, percent)
        case .discharging: shown = min(held, percent)
        // Nothing to hold to. Until there is a trend the figure is whatever was
        // read, flicker and all — inventing a floor here would hold a number
        // against a direction nobody has established.
        case .unknown: shown = percent
        }
    }

    // MARK: - What the readings add up to

    /// Charging, discharging, or whatever it was.
    ///
    /// A line fitted across the last `trendWindow` of readings, and the rule it
    /// applies is the physics: a charger holds a float voltage, so raw rising
    /// OR steady is charging and only raw falling is a battery being spent.
    /// Rising and steady collapsing into one verdict is what makes the deadband
    /// safe — inside it the wander can only ever move the answer between two
    /// readings of the same thing.
    ///
    /// Not the last two samples, which is what this replaces: the reading
    /// wanders a step or two on its own, so consecutive comparison changes its
    /// mind every few polls, and did so four times across four minutes of a
    /// measured charge.
    ///
    /// Holds the previous verdict when there is not enough window — a poll or
    /// two into a launch, or on the far side of a long gap. A glyph blanked
    /// every time a poll ran late is a worse answer than the last real one.
    private static func direction(
        of samples: [Sample], holding previous: BatteryDirection
    ) -> BatteryDirection {
        guard let last = samples.last else { return previous }
        let recent = samples.filter { last.at.timeIntervalSince($0.at) <= trendWindow }
        guard let first = recent.first else { return previous }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= minimumTrendSpan, let slope = rawSlope(of: recent) else { return previous }
        // The fall the fit accounts for across what was actually watched, rather
        // than the rate itself. A deadband on a rate would have to be re-derived
        // for every window length; this one is directly the raw steps the
        // reading is allowed to have wandered by.
        return slope * span < -Double(steadyBand) ? .discharging : .charging
    }

    /// Seconds to empty, or nil while there is not enough observed to say.
    ///
    /// How far the raw figure is above empty, over how fast it is falling. Both
    /// halves are raw, and that is the point: `bat` is derived from this same
    /// reading by the firmware and clamped at the top, so a percentage over a
    /// percent-per-second is an estimate built on a number that stops moving
    /// exactly where the raw one still does. Raw spans about 190 steps across a
    /// whole charge, against the percentage's hundred flickering ones.
    ///
    /// Every gate below is a different way of not having a rate.
    private var timeRemaining: TimeInterval? {
        guard direction == .discharging else { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }
        guard last.at.timeIntervalSince(first.at) >= Self.minimumSpan else { return nil }
        // Zero is the reading sitting still with nothing to divide, and negative
        // cannot reach here past the direction gate. Either renders as "forever".
        guard let falling = rateRawPerSecond, falling > 0 else { return nil }
        // Below the firmware's own zero the map has nothing left to say.
        // Extrapolating past the end of the scale answers a negative duration,
        // which the panel would floor and render as a confident five minutes.
        guard last.raw > Self.rawAtEmpty else { return nil }
        return Double(last.raw - Self.rawAtEmpty) / falling
    }

    /// How fast the raw figure is falling, in raw steps per second.
    ///
    /// Sign flipped, so that discharging counts up: everything downstream is
    /// about what is being SPENT, and a rate that is negative when the battery
    /// is draining would put the minus sign in every expression that touches it.
    private var rateRawPerSecond: Double? { Self.rawSlope(of: samples).map { -$0 } }

    /// The raw figure's slope against time, in raw steps per second, positive
    /// while rising.
    ///
    /// Fitted over every sample handed in rather than measured between the ends
    /// of them. Two endpoints are two readings — and two readings, one of which
    /// caught the ADC on a wobble, is the noisiest possible way to use ninety of
    /// them.
    private static func rawSlope(of samples: [Sample]) -> Double? {
        guard let start = samples.first?.at else { return nil }
        // Seconds since the first sample rather than since 1970. The fit squares
        // its x-deviations, and a billion-and-a-half squared spends the
        // precision on the epoch instead of on the window.
        return slope(of: samples.map { (x: $0.at.timeIntervalSince(start), y: Double($0.raw)) })
    }

    /// The slope of a least-squares fit of `y` against `x`, or nil when every
    /// `x` is the same and there is no line to fit.
    ///
    /// Only the slope. The intercept was the other candidate for where empty
    /// is; `rawAtEmpty` carries why the firmware's own map won that argument.
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
    /// The shown figure is not reset here either, and does not need to be: the
    /// verdict going to `.unknown` IS a change of direction, and the ratchet
    /// releases to the next reading on one.
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
