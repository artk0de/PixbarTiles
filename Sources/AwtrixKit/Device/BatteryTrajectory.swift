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

/// One reading, with the instant it was taken at.
///
/// The raw figure and nothing else. `bat` used to be carried here too, to
/// derive how many raw steps the firmware spends on a percent; the estimate is
/// raw-native now and nothing in the fit has a use for a percentage.
///
/// Public and `Codable` because this is also the shape the readings are written
/// down in. A separate on-disk type was the alternative, and it would be this
/// one field for field plus a mapping in each direction — two places to add the
/// next field to, and a fit that reads whichever of them was updated.
public struct BatterySample: Sendable, Codable, Equatable {
    public let raw: Int
    public let at: Date

    public init(raw: Int, at: Date) {
        self.raw = raw
        self.at = at
    }
}

/// Everything one launch has to hand the next one about the battery.
///
/// The readings, and the two facts that say whether they still describe the
/// clock in front of us. Without the uid a restored series cannot be told from
/// another device's, and without the uptime a reboot in the gap is invisible —
/// so the three travel together or the record is only ever part of an answer.
///
/// What is NOT in here is the verdict, the ratcheted figure, or which warnings
/// are still armed. The verdict is derived from the samples and is recomputed
/// from them; the ratchet exists to stop a figure flickering on screen and
/// there is no screen across a relaunch; the armed set is a function of the
/// percentage the next poll reports, so it re-arms itself.
public struct BatteryHistory: Sendable, Codable, Equatable {
    /// Which clock the readings came off.
    public let uid: String
    /// How long that clock had been up when the last of them arrived, or nil
    /// where the firmware does not report it.
    public let uptime: Int?
    /// The readings themselves, oldest first.
    public let samples: [BatterySample]

    public init(uid: String, uptime: Int?, samples: [BatterySample]) {
        self.uid = uid
        self.uptime = uptime
        self.samples = samples
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
    ///
    /// Nothing reaches the estimate through less than this any more, because a
    /// discharge is not believed off less than `minimumFallSpan` and that is
    /// longer. Kept rather than deleted: it is the estimate's OWN precondition,
    /// and an estimate whose only guard lives in the direction rule is one that
    /// silently loosens the day somebody shortens the fall's span.
    public static let minimumSpan: TimeInterval = 15 * 60
    /// How far back a RISE is read over, as against the rate.
    ///
    /// Short, because a charge is loud. Measured on this clock: 664, and 669
    /// two minutes later — twenty-five raw steps per ten minutes. Ten minutes
    /// of that is twenty-five steps of signal against the two the reading
    /// wanders by, so watching longer buys nothing and a charger plugged in now
    /// is seen within a few readings. Fitted across the whole ninety the RATE
    /// uses, a clock plugged in now would go on reading as discharging for most
    /// of an hour.
    ///
    /// It was the window for BOTH answers until the discharge was measured, and
    /// that WAS the defect: a real fall over ten minutes is smaller than the
    /// wander over the same ten minutes, so no threshold on this window could
    /// ever have found one, and every discharge read as a charge.
    public static let riseWindow: TimeInterval = 10 * 60
    /// How far back a FALL is read over.
    ///
    /// Six times the rise's window, because the two signals are nothing like
    /// the same size. Measured on the same clock, on battery: 646 to 642 across
    /// 30.1 minutes — 1.33 raw steps per ten minutes, a twentieth of the
    /// charge, and smaller than the two steps the same series wanders by inside
    /// ten. Across an hour that rate spends about seven steps, which clears the
    /// wander with room to spare.
    ///
    /// An hour and not the ninety minutes the rate is fitted over. Sixty is
    /// already twice what the band needs at the measured rate, and every extra
    /// minute is a minute a charge that has just ended stays inside the window
    /// slowing the next discharge down.
    ///
    /// What it costs is stated plainly: a clock unplugged now goes on saying
    /// charging for about half an hour, and for the best part of an hour if it
    /// was unplugged straight off a charge, because the charge's rise is still
    /// inside this window. That is the price of not calling every wobble a
    /// discharge, and the wobble is real — this clock's own series drops three
    /// steps in two minutes and takes them back four minutes later.
    public static let fallWindow: TimeInterval = 60 * 60
    /// How much of that has to have been watched before there is a verdict at
    /// all.
    ///
    /// A flat window means "settled on the charger's float" and "nothing has
    /// been watched yet" equally well, and two minutes is where the second
    /// stops being the likely one. `.unknown` stays a real state until then: a
    /// verdict the readings cannot support is worse than none.
    public static let minimumTrendSpan: TimeInterval = 2 * 60
    /// How much has to have been watched before a FALL is believed, whatever
    /// the fit says about it.
    ///
    /// Twenty minutes. At the measured 1.33 steps per ten minutes a fall worth
    /// the band takes about twenty-five to accumulate anyway, so this costs a
    /// real discharge nothing at the rate this clock actually runs at.
    ///
    /// What it buys is margin the band has none of at short spans. The measured
    /// series' own worst moment — 644 for nine samples, then 641 — is three
    /// steps inside two minutes, and a fit over just those readings falls
    /// exactly three: level with the band, and a step deeper than any wobble
    /// yet measured would be past it. The band cannot be the only thing between
    /// a wobble and a verdict when the worst wobble lands on it exactly.
    ///
    /// Widening the band was the alternative. Rejected because the band is also
    /// what the SLOWEST measured discharge has to clear, and at 4.2 steps in an
    /// hour against three it has 1.4x of room and no more.
    public static let minimumFallSpan: TimeInterval = 20 * 60
    /// How far the fitted trend has to carry the raw figure, in either
    /// direction, before it counts as more than the reading wandering.
    ///
    /// Three raw steps, and NOT changed by the discharge measurement — it was
    /// the window that was wrong, not the number. Sized against the clock at
    /// rest: settled on the float it answers between 667 and 669, and the worst
    /// line fitted through any trailing part of that window falls 1.73 steps,
    /// against which three is 1.7x clear. The ceiling is the other end: the
    /// slowest discharge ever measured here loses 4.2 raw steps an hour, so a
    /// band of four leaves it a fifth of a step of margin across the whole
    /// window and a band of five would not see it at all.
    ///
    /// Symmetric on purpose. The wander is the ADC's and reads the same in both
    /// directions; it is the SIGNALS that are twenty to one, and that asymmetry
    /// is carried by the two windows above. Two bands were the alternative, and
    /// they would have had to be re-derived together every time either window
    /// moved.
    ///
    /// Not made smaller for the longer window, though a fit over sixty samples
    /// averages the wander down further than one over ten: there is no
    /// hour-long measurement of the float to size a smaller band against, and
    /// the clock cannot be asked for one without plugging it in.
    public static let steadyBand = 3

    /// How long readings are kept.
    ///
    /// A day, against the ninety minutes `window` keeps for the direction. The
    /// two are separate numbers with separate jobs: direction is a question
    /// about the last hour, and the rate on the plateau needs an arm long
    /// enough that the fall outgrows the sag — which there can take most of an
    /// afternoon.
    public static let retention: TimeInterval = 24 * 60 * 60
    /// Beyond `window`, one reading every five minutes is kept and the rest
    /// dropped. The slope is unchanged by the thinning and the stored series
    /// stays a few hundred points.
    static let thinTo: TimeInterval = 5 * 60
    /// How far the fitted fall must outgrow the sag before an estimate is shown.
    ///
    /// Two, which is the smallest ratio that is not arguing with the noise. One
    /// would show an estimate the moment the signal merely matched the wobble;
    /// three would keep the plateau silent for a whole working day.
    static let signalToNoise = 2.0
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
    ///
    /// Read twice, and as the same fact both times: it is where the estimate
    /// stops counting down, and it is the floor `record(_:at:)` will accept a
    /// reading at all above. Below the bottom of the firmware's own scale there
    /// is nothing to interpret in either direction — which is why the guard
    /// there names this rather than a number of its own.
    public static let rawAtEmpty = 475
    /// Where a warning fires, in percent. Ordered high to low, and read as a
    /// set rather than in order — a poll can find the battery below several at
    /// once.
    ///
    /// The lowest of them carries a rule the others do not: it is the one
    /// `crossing(at:)` fires without waiting for a direction. That rule reads
    /// it back out with `min()` rather than naming the number, so the last line
    /// is written down once and moving it moves the emergency with it.
    public static let thresholds = [20, 10, 5, 1]
    /// How far back over a threshold the battery has to climb before that
    /// threshold can fire again.
    ///
    /// Without it, a battery hovering either side of 20% warns on every wobble
    /// — the same storm the edge trigger exists to stop, arriving more slowly.
    public static let rearmMargin = 3

    /// Readings inside the window, oldest first. Only ones carrying a raw
    /// figure: a firmware that omits it contributes a percentage and no trend.
    private var samples: [BatterySample] = []
    /// When the battery was last seen going UP.
    ///
    /// The rate is fitted only over what came after it. With samples kept for a
    /// whole day, a fit over "everything held" would be dragged through the
    /// charge that preceded the discharge — a rise and a fall averaged into a
    /// gentle nothing, and an estimate of days.
    private var lastSeenRising: Date?
    /// The whole of the last report, which is what the percentage is read off,
    /// so that a clock with no raw figure still has one.
    ///
    /// This launch's only. It is not restored from a stored series and must not
    /// be: a percentage read before the app was closed is a reading nobody took
    /// now, and `reading` would hand it to the panel before the first poll of
    /// this launch has answered.
    private var latest: DeviceStats?
    /// Which clock the readings in `samples` came off, and how long it had been
    /// up when the last of them arrived.
    ///
    /// Read off the same report `latest` is and kept beside it, which is a
    /// duplication with a reason: this pair survives a launch and `latest` does
    /// not. They are not readings — they are what says whether the readings
    /// beside them still describe the clock now answering — so they are exactly
    /// what a stored series can be checked against.
    private var seriesUid: String?
    private var seriesUptime: Int?
    private var direction: BatteryDirection = .unknown
    /// The ratcheted figure, or nil before anything has been recorded.
    private var shown: Int?
    /// Thresholds that may still fire. Everything to begin with: a first poll
    /// finding the battery already at 4% has news, and it is only the direction
    /// gate that holds it back until there is a trend to gate on — down to the
    /// last line, which that gate no longer holds at all.
    private var armed: Set<Int> = Set(BatteryTrajectory.thresholds)

    /// A fresh trajectory, or the one a previous launch wrote down.
    ///
    /// The samples come back AND the two facts they are checked against, and
    /// that pairing is the whole of what makes resuming safe: the first live
    /// reading goes through `invalidates(_:at:)` exactly as a mid-session one
    /// does, so a series off another clock, from before a reboot, or older than
    /// the window is discarded and this launch starts cold — correctly.
    /// Restoring the readings alone would defeat all three checks at once,
    /// because each of them compares against something the series carries.
    ///
    /// The verdict is recomputed here rather than stored, for the reason
    /// `BatteryHistory` gives: a stored one could only be trusted or dropped.
    /// Recomputing also puts a resumed launch in exactly the state an
    /// uninterrupted one would be in, which is what makes a late first poll
    /// hold the trend across the gap instead of blanking it.
    ///
    /// Nothing is READABLE off this until a poll answers — `latest` stays nil,
    /// so `reading` does — so a restored verdict is never shown beside a
    /// percentage from before the relaunch.
    public init(resuming history: BatteryHistory? = nil) {
        guard let history else { return }
        samples = history.samples
        seriesUid = history.uid
        seriesUptime = history.uptime
        direction = Self.direction(of: samples, holding: .unknown)
    }

    /// What this launch has to hand the next one, or nil while it has nothing
    /// to say.
    ///
    /// Nil before the first reading, and deliberately not an empty series: a
    /// record naming no clock cannot be checked against the device that answers
    /// next, and the check is the whole reason the record is safe to resume
    /// from.
    public var history: BatteryHistory? {
        guard let seriesUid else { return nil }
        return BatteryHistory(uid: seriesUid, uptime: seriesUptime, samples: samples)
    }

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
        // A raw figure below the firmware's own empty is not a reading, and is
        // turned away before it can become one. Sampled through a power-on of the
        // clock on this desk: `uptime=25` answered `bat=0, bat_raw=0`, and
        // seventeen seconds later `uptime=42` answered `bat=98, bat_raw=662`. No
        // battery crosses 98 points in seventeen seconds — the firmware answers
        // the request before it has read the converter. The window is twenty to
        // forty seconds against a poll of sixty, so every reboot of the clock is
        // a coin toss on catching one.
        //
        // First statement of the whole method, which is what "not a reading"
        // means: no sample, no `latest`, no warning, no verdict disturbed, not
        // even the uid and uptime. Anything later in the method leaves a trace
        // of a reading that never happened.
        //
        // This belongs with the rule above it rather than after it. `thresholds`
        // fires its lowest line while the direction is still `.unknown`, because
        // a verdict costs twenty-two minutes and the last line is ten of
        // runtime — and the first poll after a reboot is precisely a moment when
        // the direction is necessarily `.unknown`. One rule spends the evidence
        // gate on the emergency; the other is what keeps a non-reading from
        // walking through the gap it opened. Left in, the zero is also +662
        // against the next real reading, which is six hundred steps against a
        // band of three: an instant, confident, wrong `.charging`.
        //
        // On the RAW figure, though both halves of this report are wrong. `bat`
        // is derived from the raw one and clamped, so a firmware answering a bad
        // percentage over a good raw reading would be second-guessed for
        // nothing; the raw figure is the diagnostic half of the pair. The
        // boundary belongs to the battery: `rawAtEmpty` IS zero percent by the
        // firmware's own map and is recorded as one, and only what falls off the
        // bottom of that scale — absent hardware, or a converter not yet read —
        // is dropped.
        //
        // Dropped, and pointedly not handed to `invalidates(_:at:)`. That rule
        // is for a reading describing a DIFFERENT situation and it answers by
        // discarding the history, which was the alternative here and is the
        // wrong shape twice over: this clock is the same clock, and throwing
        // away twenty minutes of established trend over one bad reading spends
        // exactly what the last line's exception exists to protect. The reboot
        // that produced the zero is still there to be caught, by the first real
        // reading that follows it — which is the reading that can be checked.
        //
        // A firmware omitting `bat_raw` altogether is untouched and stays the
        // case it already was: a percentage and no trend.
        if let raw = stats.batRaw, raw < Self.rawAtEmpty { return nil }
        if invalidates(stats, at: now) { discardHistory() }
        latest = stats
        seriesUid = stats.uid
        seriesUptime = stats.uptime
        // Held across the recompute, because the ratchet is released by a CHANGE
        // of direction and there is nowhere else to see one from.
        let before = direction
        if let raw = stats.batRaw {
            samples.append(BatterySample(raw: raw, at: now))
            prune(at: now)
            direction = Self.direction(of: samples, holding: direction)
            if direction == .charging { lastSeenRising = now }
        }
        ratchet(to: stats.bat, wasGoing: before)
        // On `bat`, and that is now known to be wrong — left alone deliberately
        // rather than by oversight.
        //
        // Logged to the moment this clock went flat, the firmware read 47. So
        // every threshold here — 20, 10, 5, 1 — is below anything it will ever
        // report, and all four warnings are unreachable on this hardware. The
        // fix is to read `BatteryChargeCurve.percent(atRaw:)` instead, which is
        // one line; what stops it being made here is that it moves eight tests
        // covering arming, re-arming and lowest-of-many crossings, and those
        // describe behaviour nobody has asked to change. Their fixtures pair a
        // percentage with a raw figure by the firmware's map, so the change is
        // a rewrite of what they mean rather than a repair.
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
    /// Two questions over two windows rather than one rule over one, and the
    /// physics is what splits them: a charger holds a float voltage, so a
    /// charge is loud and a discharge is a slow leak. Measured on this clock
    /// the two differ by twenty to one — twenty-five raw steps per ten minutes
    /// against 1.33 — so one window cannot serve both. Wide enough to hear the
    /// fall it takes twenty minutes to notice a charger; quick enough to notice
    /// the charger it cannot hear the fall at all, which is the reported
    /// defect: a discharge on this clock never spends three raw steps inside
    /// ten minutes, so the fall gate never tripped and every discharge read as
    /// a charge.
    ///
    /// The rise is asked FIRST, and that ordering is what keeps a charge from
    /// being read off the fall it interrupted: the hour behind a clock plugged
    /// in a minute ago is still falling, while the ten minutes in front of it
    /// climb twenty times faster.
    ///
    /// Steady is charging, and so is a fall that fails either of its gates.
    /// Answering `.unknown` to everything unproven was the alternative, and it
    /// would blank the glyph for the whole of the clock's life on the charger,
    /// which is most of it.
    ///
    /// Both answers come off a fitted line and neither off the last two
    /// samples, which is what the fit originally replaced: the reading wanders
    /// a step or two on its own, so consecutive comparison changes its mind
    /// every few polls, and did so four times across four minutes of a measured
    /// charge.
    ///
    /// Holds the previous verdict when there is not enough window — a poll or
    /// two into a launch, or on the far side of a long gap. A glyph blanked
    /// every time a poll ran late is a worse answer than the last real one.
    private static func direction(
        of samples: [BatterySample], holding previous: BatteryDirection
    ) -> BatteryDirection {
        guard let rise = fittedChange(of: samples, over: riseWindow, needing: minimumTrendSpan)
        else { return previous }
        if rise > Double(steadyBand) { return .charging }

        // Pinned at the top of the scale, which is a charger holding it there:
        // a cell resting above 4.2 V is being held above it by something. Asked
        // BEFORE the fall window, and needing only the rise window's two
        // minutes, because sitting still at the top is not a trend anybody has
        // to fit — waiting twenty minutes to notice it would blank the glyph
        // for the state the clock spends most of its life in.
        if samples.last.map({ $0.raw >= BatteryChargeCurve.rawAtFull - 2 }) == true {
            return .charging
        }

        // Not enough watched to fit a fall yet. HELD, not called charging — and
        // that word is the defect this replaced. A discharge needs twenty
        // minutes before it can be fitted while a rise needs two, so answering
        // `.charging` here labelled the first eighteen minutes of EVERY
        // discharge as a charge: the plug glyph on a clock nobody had plugged
        // in, which is exactly what was reported and was not fixed by making
        // the windows asymmetric.
        guard let fall = fittedChange(of: samples, over: fallWindow, needing: minimumFallSpan)
        else { return previous }
        if fall < -Double(steadyBand) { return .discharging }

        // Steady, and not at the top. Nothing has moved far enough to say, so
        // the previous verdict stands rather than being replaced by a guess.
        // Before there is any verdict that is `.unknown`, which the panel draws
        // as an hourglass: honest, and the thing the plug was lying about.
        return previous
    }

    /// How many raw steps the fitted line accounts for across the readings
    /// inside `window`, or nil when fewer than `span` seconds of them have been
    /// watched.
    ///
    /// The change across what was ACTUALLY watched rather than the rate itself,
    /// which is what lets one band serve two windows: `steadyBand` is directly
    /// the raw steps the reading is allowed to have wandered by. A band on a
    /// rate would have to be a different number for each window, and moving one
    /// window would silently change what the other one believed.
    private static func fittedChange(
        of samples: [BatterySample], over window: TimeInterval, needing span: TimeInterval
    ) -> Double? {
        guard let last = samples.last else { return nil }
        let inside = samples.filter { last.at.timeIntervalSince($0.at) <= window }
        guard let first = inside.first else { return nil }
        let watched = last.at.timeIntervalSince(first.at)
        guard watched >= span, let slope = rawSlope(of: inside) else { return nil }
        return slope * watched
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
        let series = fallSeries
        guard let first = series.first, let last = series.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minimumSpan else { return nil }
        // Zero is the reading sitting still with nothing to divide, and negative
        // cannot reach here past the direction gate. Either renders as "forever".
        guard let falling = chargePerSecond, falling > 0 else { return nil }

        // The fall has to be bigger than the wobble it is being seen through,
        // and BOTH are measured in charge — which is the whole reason the curve
        // exists. Three raw steps of load-sag are worth a fraction of a point
        // near the top of the curve and several points on the plateau, so a
        // threshold fixed in either unit is right in one region and wrong
        // everywhere else. Converting the band through the curve at the reading
        // in hand is what makes one rule cover the whole discharge.
        //
        // The consequence is honest and worth stating: unplugged at the top,
        // this opens within the hour and then STAYS open, because the series
        // keeps growing and the fit keeps improving. Started fresh in the
        // middle of the plateau, it can stay shut for hours — and hours of
        // saying nothing is the correct answer there, because the voltage
        // genuinely does not carry the rate yet.
        let sag = Double(Self.steadyBand) * BatteryChargeCurve.percentPerRaw(atRaw: last.raw)
        guard falling * span >= Self.signalToNoise * sag else { return nil }

        // What is left is CHARGE, not volts above a floor. The old expression
        // divided the raw distance above `rawAtEmpty` by a raw-per-second rate,
        // and on the plateau that rate is at its smallest — so the estimate was
        // at its largest exactly where the battery was emptiest.
        let left = BatteryChargeCurve.percent(atRaw: last.raw)
        guard left > 0 else { return nil }
        return left / falling
    }

    /// The samples the rate may be fitted over: everything since the battery was
    /// last seen going up.
    private var fallSeries: [BatterySample] {
        guard let since = lastSeenRising else { return samples }
        return samples.filter { $0.at > since }
    }

    /// How fast charge is being spent, in percent per second, positive while
    /// draining.
    ///
    /// Charge rather than volts, and that substitution IS the fix. A cell at
    /// constant load spends charge at a constant rate; it does not lose voltage
    /// at a constant rate, because the curve it walks down is flat in the middle
    /// and steep at the ends.
    private var chargePerSecond: Double? {
        let series = fallSeries
        guard let start = series.first?.at else { return nil }
        let points = series.map {
            (x: $0.at.timeIntervalSince(start), y: BatteryChargeCurve.percent(atRaw: $0.raw))
        }
        guard let slope = Self.slope(of: points), slope < 0 else { return nil }
        return -slope
    }

    /// Keeps a day of readings, thinned beyond the direction window.
    ///
    /// Two different retentions for two different jobs. Direction is a question
    /// about the last hour and is answered from the dense tail; the RATE on the
    /// plateau needs a long arm, because there the whole day's fall can be a
    /// handful of raw steps. Beyond `window` one sample every `thinTo` carries
    /// the same slope at a fraction of the storage — a day comes to a few
    /// hundred points, which is kilobytes of JSON.
    private mutating func prune(at now: Date) {
        samples.removeAll { now.timeIntervalSince($0.at) > Self.retention }
        var kept: [BatterySample] = []
        var lastThinned: Date?
        for sample in samples {
            if now.timeIntervalSince(sample.at) <= Self.window {
                kept.append(sample)
                continue
            }
            if let lastThinned, sample.at.timeIntervalSince(lastThinned) < Self.thinTo { continue }
            kept.append(sample)
            lastThinned = sample.at
        }
        samples = kept
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
    private static func rawSlope(of samples: [BatterySample]) -> Double? {
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
    ///
    /// "The last one" reaches back through a relaunch, because the series does:
    /// a restored one arrives with the same uid, uptime and instant a live one
    /// would have left behind, so all three questions are asked of it without
    /// knowing or caring that the app was closed in between. A second rule for
    /// restored series was the alternative, and two copies of a rule this
    /// load-bearing is how one of them quietly stops matching the other.
    private func invalidates(_ stats: DeviceStats, at now: Date) -> Bool {
        guard let seriesUid else { return false }
        // A different clock entirely: the address was repointed, or two of them
        // answer on it in turn.
        if stats.uid != seriesUid { return true }
        // Uptime going backwards is a reboot, and a reboot is exactly when
        // somebody unplugged the clock and plugged it in again.
        if let now = stats.uptime, let before = seriesUptime, now < before { return true }
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
    ///
    /// The uid and the uptime survive too, and are meant to: `record` writes
    /// them from the very reading that caused the discard, on the line after
    /// this one. Clearing them here would leave the new series describing the
    /// old clock for exactly one statement.
    private mutating func discardHistory() {
        samples = []
        direction = .unknown
        lastSeenRising = nil
    }

    // MARK: - Warnings

    /// Re-arms what the battery has climbed clear of, and fires what it has
    /// just fallen through.
    ///
    /// In that order, and both halves are deliberate about what they skip.
    /// Re-arming runs whatever the direction is, because it is about where the
    /// battery is rather than where it is going. Firing reads the direction, and
    /// reads all three of its answers rather than folding two of them together.
    private mutating func crossing(at percent: Int) -> BatteryWarning? {
        for threshold in Self.thresholds where percent >= threshold + Self.rearmMargin {
            armed.insert(threshold)
        }
        let crossed = Self.thresholds.filter { percent <= $0 && armed.contains($0) }
        // The lowest, not the first. A poll can find the battery a long way
        // below where it left it — the Mac slept, or the clock was off the
        // network for an hour — and three dialogs at once is not three times
        // the information. The ones it fell past go with it rather than
        // queueing up to fire on the next poll.
        guard let fired = crossed.min() else { return nil }
        switch direction {
        case .discharging:
            break
        // A clock KNOWN to be filling up has no news however low it reads, and
        // it must not spend the crossing either: one charging up through 4%
        // that DISARMED the 5% line would let the discharge that follows pass
        // the same threshold in silence.
        case .charging:
            return nil
        // No verdict yet, and on the last line: fire anyway.
        //
        // The gate above exists to stop a charging clock warning on its way up
        // through 20%, which is a real nuisance and worth a wait. At the last
        // line the trade inverts. A verdict costs 22 minutes from a standing
        // start and up to 55 straight off a charge — the fall is read over an
        // hour because it is smaller than the reading's own wander over
        // anything less — while the last line is ten to seventeen minutes of
        // runtime. Waiting to be sure means the warning that matters most is
        // the one that cannot arrive before the clock goes dark. A spurious
        // dialog about a clock that turns out to be charging costs one dismissal;
        // the missing one costs the thing going dark with no word.
        //
        // The last line ALONE, and that is what keeps this from being "warn
        // whenever we do not know": 20% unverified is hours of runtime, and
        // firing the upper lines on no evidence is how a warning becomes noise
        // people learn to ignore.
        //
        // Shortening the fall window was the alternative, and it is closed:
        // `steadyBand` is already within 1.4x of the slowest measured discharge,
        // so a window short enough to answer in ten minutes cannot tell that
        // discharge from the wander at all. The gap is in what the readings can
        // support, not in how they are read, and no window arithmetic removes
        // it.
        //
        // What it SPENDS is the whole crossed set, exactly as a discharging
        // crossing does. Firing the last line and leaving the ones above it
        // armed would have the verdict, twenty minutes later, announce 5% at a
        // battery reading 1%.
        case .unknown:
            guard fired == Self.thresholds.min() else { return nil }
        }
        armed.subtract(crossed)
        return BatteryWarning(threshold: fired, percent: percent)
    }
}
