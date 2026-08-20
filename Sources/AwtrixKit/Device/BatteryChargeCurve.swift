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
    /// The firmware's ends, which are also this curve's.
    ///
    /// Pinned rather than merely approached. Everything downstream divides what
    /// is left by a rate, and a curve answering four percent at the firmware's
    /// own zero would leave an estimate that never reaches the end of the
    /// battery.
    public static let rawAtEmpty = 475
    public static let rawAtFull = 665

    /// Voltage against charge, as `(raw, percent)` in ascending order.
    ///
    /// Read off the canonical curve at 6.45 mV per step: 4.20 V is a full cell
    /// at 651, the plateau runs from about 3.78 V to 3.92 V — raw 586 to 608 —
    /// and everything below 3.60 V is the bottom knee, which is steep enough
    /// that eighty raw steps carry only the last five points of charge.
    ///
    /// The top sliver carries one point of charge rather than none, and that
    /// is a modelling convenience with a reason. Above 4.20 V a cell is full or
    /// on a charger, so honestly it is all one state — but `percentPerRaw` is
    /// what the estimate's gate divides by, and a genuinely flat segment would
    /// hand it a zero. One point spread over 4.20 to 4.29 V costs nothing in a
    /// region the battery cannot rest at and removes the divide entirely.
    static let nodes: [(raw: Int, percent: Double)] = [
        (475, 0),    // 3.06 V — the firmware's zero
        (558, 5),    // 3.60 V
        (569, 10),   // 3.67 V
        (578, 20),   // 3.73 V
        (586, 30),   // 3.78 V — plateau begins
        (591, 40),   // 3.81 V
        (595, 50),   // 3.84 V
        (600, 60),   // 3.87 V
        (608, 70),   // 3.92 V — plateau ends
        (617, 80),   // 3.98 V
        (629, 90),   // 4.06 V
        (651, 99),   // 4.20 V — a full cell
        (665, 100),  // 4.29 V — the firmware's ceiling
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
