import Foundation

/// How much charge is left in the cell, from the voltage the clock reports.
///
/// `bat_raw` is an ADC reading of the battery's voltage — GPIO34 through a
/// divider, median-and-mean filtered in the firmware, ten bits — so one raw
/// step is about 6.45 mV and the firmware's own ends, 475 and 665, are roughly
/// 3.06 V and 4.29 V.
///
/// Voltage is not charge. A lithium cell sits on a long flat plateau through
/// the middle of its discharge and falls steeply at both ends, so equal steps
/// in volts are wildly unequal steps in charge. The firmware maps the two
/// linearly, and this app used to as well: it divided the raw distance above
/// empty by a raw-per-second rate, both measured in volts. On the plateau that
/// rate is at its smallest, so the estimate is at its largest — the reason a
/// falling battery reported a GROWING time remaining, which is what was
/// actually being complained about.
///
/// The shape below is the canonical single-cell lithium-polymer discharge
/// curve, not a fit to this device: nothing has yet watched this clock cross
/// its own plateau. It is accurate to the shape of the family rather than to
/// this cell, which is why what is built on it reports bands and not minutes.
/// A calibration against an observed discharge would replace these nodes and
/// nothing else.
public enum BatteryChargeCurve {
    /// Where this cell actually runs out, which is not where the firmware says.
    ///
    /// 564, measured. The clock was logged once a minute from a full charge
    /// until it went silent at raw 564 after twelve and a half hours, and the
    /// sample after the silence reported an uptime of seventy-two seconds — a
    /// power cycle, at the end of a voltage collapse that was accelerating
    /// while the matrix was at its dimmest. It ran flat.
    ///
    /// The firmware called that moment 47%. Its map runs to 475, which is
    /// 3.06 V — a voltage this cell never reaches, because the board stops
    /// first. Extrapolating to it is what made every estimate above this
    /// generous, and it is why `bat` cannot be reasoned from.
    public static let rawAtEmpty = 564
    public static let rawAtFull = 665

    /// Voltage against charge, as `(raw, percent)` in ascending order.
    ///
    /// MEASURED on this clock rather than taken from the canonical shape of the
    /// family. One discharge was logged once a minute from boot to the moment
    /// it went flat — twelve and a half hours — and charge here is simply how
    /// much of that runtime was still to come at each reading. That is the
    /// definition that matters to somebody looking at the panel: not how full
    /// the cell is in coulombs, but how much of the evening is left.
    ///
    /// Read beside the firmware's own answer, the size of its error is the
    /// point of this table: it called raw 612 seventy-two percent when eleven
    /// hours of the twelve and a half were already gone, and called the moment
    /// the clock died forty-seven.
    ///
    /// The top third is the honest weakness. Logging began three and three
    /// quarter hours into the run, at raw 631, so everything above that is a
    /// straight line drawn to a full cell — no measurement stands behind it,
    /// and a charge watched from full would replace those two entries.
    static let nodes: [(raw: Int, percent: Double)] = [
        (564, 0),    // the reading it went silent on
        (572, 3),
        (580, 6),
        (588, 10),
        (596, 17),
        (604, 32),
        (612, 44),
        (620, 51),
        (628, 61),
        (631, 65),   // the first reading of the log
        (665, 100),  // assumed, not measured — see above
    ]

    /// The charge left at this reading, nought to a hundred.
    ///
    /// Clamped rather than extrapolated at both ends: outside the firmware's
    /// scale there is no curve to follow, and a straight line drawn past it
    /// answers a negative charge or one above full.
    public static func percent(atRaw raw: Int) -> Double {
        if raw <= rawAtEmpty { return 0 }
        if raw >= rawAtFull { return 100 }

        for (lower, upper) in zip(nodes, nodes.dropFirst()) where raw <= upper.raw {
            guard raw >= lower.raw else { continue }
            let span = Double(upper.raw - lower.raw)
            guard span > 0 else { return lower.percent }
            let along = Double(raw - lower.raw) / span
            return lower.percent + along * (upper.percent - lower.percent)
        }
        return 100
    }

    /// How much charge one raw step is worth at this reading.
    ///
    /// The gate in front of the estimate needs it: the noise it has to see
    /// through is measured in raw steps, and the fall it is comparing against
    /// is measured in charge. Without this the two cannot be compared at all,
    /// and a fixed threshold in either unit is right in one region of the curve
    /// and wrong everywhere else.
    ///
    /// A central difference rather than the slope of one segment, so a reading
    /// that lands exactly on a node does not inherit whichever side it was
    /// compared against first.
    public static func percentPerRaw(atRaw raw: Int) -> Double {
        let above = percent(atRaw: min(rawAtFull, raw + 2))
        let below = percent(atRaw: max(rawAtEmpty, raw - 2))
        let span = Double(min(rawAtFull, raw + 2) - max(rawAtEmpty, raw - 2))
        guard span > 0 else { return 0 }
        return (above - below) / span
    }
}
