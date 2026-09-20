import PixelClockKit
import SwiftUI

/// The selected clock's status: connectivity, address, battery when the clock
/// reports one, and the discovery line when there is something to say.
///
/// Composition over the existing status lines — `DeviceStatusLine`,
/// `DiscoveryStatusLine` and `BatteryLine`, which stay where they are until
/// the switch-over moves them beside this block. No new line text is invented
/// here; the block only decides WHICH of them the clock's inputs earn.
///
/// A nil battery is no battery CELL, not a placeholder: the TC002's stock
/// firmware answers no level over its API, so whatever drew there would be a
/// guess. Which clock can report one is decided upstream — the block is
/// handed nil and draws nothing.
struct ClockStatusBlock: View {
    let state: DeviceState
    let address: String
    let battery: BatteryReading?
    let discovery: DiscoveryState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DeviceStatusLine.colour(for: state))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DeviceStatusLine.title(for: state))
                        .font(.headline)
                    // The address and the battery in one row but two labels:
                    // only the second of them turns orange, and a single
                    // string would have taken the address with it.
                    HStack(spacing: 4) {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let line = battery.map(BatteryLine.text) ?? nil {
                            Text("· " + line)
                                .font(.caption)
                                .foregroundStyle(BatteryLine.colour(for: battery))
                        }
                    }
                }
            }
            if let line = discovery.map(DiscoveryStatusLine.text) ?? nil {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The status lines, moved here at the switch-over (D10 — as they were)

/// What the dot and the line above it say about the device.
///
/// Three states, not two. `isOnline` is false for `.unknown` as much as for
/// `.offline`, so a panel opened before the first poll has answered announced a
/// disconnection it had no grounds for. That conflation is the same one
/// `DeviceState` exists to prevent.
enum DeviceStatusLine {
    static func title(for state: DeviceState) -> String {
        switch state {
        case .unknown: "Checking…"
        case .online: "Connected"
        case .offline: "Disconnected"
        }
    }

    static func colour(for state: DeviceState) -> Color {
        switch state {
        case .unknown: .secondary
        case .online: .green
        case .offline: .red
        }
    }
}

/// What the line under the status says about the network.
///
/// Five answers rather than a list that may be empty, because "you have not
/// been asked yet", "still looking", "nothing is advertising here" and "you
/// refused this app the local network" all render as zero devices and only one
/// of them is fixed by plugging the clock in. A panel that says "no devices
/// found" to somebody who declined the permission prompt has sent them to look
/// at their router.
///
/// No line names a model: the discovery is two ears — the AWTRIX browse and
/// the TC002 broadcasts — and a line that claimed only AWTRIX read as a lie
/// to everybody whose clock is a TC002.
enum DiscoveryStatusLine {
    static func text(for state: DiscoveryState) -> String? {
        switch state {
        case .idle:
            nil
        case .searching:
            "Looking for clocks…"
        case let .listed(devices):
            listing(devices)
        case let .unavailable(reason):
            "Waiting for a network to browse — \(reason)"
        case .denied:
            "Local Network access is off for this app — turn it on in System "
                + "Settings › Privacy & Security › Local Network"
        case let .failed(reason):
            "Could not look for devices: \(reason)"
        }
    }

    /// Names every instance, and never counts them.
    ///
    /// The name is the only thing a browse knows — the instance name is not a
    /// hostname, `awtrix.local` does not resolve — so "2 devices found" leaves
    /// the reader with nothing they can act on. With more than one advertising
    /// itself, the address the app talks to is the thing that decides which,
    /// and it is not something discovery may pick on the user's behalf.
    private static func listing(_ devices: [DiscoveredDevice]) -> String {
        guard devices.isEmpty == false else {
            return "No clock is advertising itself on this network"
        }
        let names = devices.map(\.instanceName).joined(separator: ", ")
        guard devices.count > 1 else { return "Seen on the network: \(names)" }
        return "Seen on the network: \(names) — the address below decides which one this "
            + "app talks to"
    }
}
/// What the panel says about the battery.
///
/// The panel, and deliberately not the menu bar item: that item is a template
/// image whose monochrome silhouette and its offline variant are both
/// load-bearing, and an emoji drawn into it would break each of them.
enum BatteryLine {
    /// Where the discharging glyph changes, and the same number the first
    /// warning fires at — one line, so the panel and the dialog cannot disagree
    /// about what "low" means.
    static let low = 20
    /// Below this the wording and the colour carry the urgency. There is no red
    /// variant of either battery emoji, and stacking a warning sign beside one
    /// reads as clutter rather than as escalation.
    static let critical = 10

    /// The emoji for the state, or none while there is no state.
    ///
    /// There is no "battery charging" emoji in Unicode — the family is U+1F50B
    /// and U+1FAAB, and neither has a charging variant — so charging shows the
    /// plug, which is the closest thing that exists and reads unambiguously
    /// next to a percentage.
    ///
    /// While the trend is not established the mark is an hourglass, and it is
    /// chosen for what it does NOT say. The plug says mains, both batteries say
    /// cell, and the app cannot support any of the three yet — guessing one is
    /// what `.unknown` exists to stop. An hourglass claims only that an answer
    /// is being worked out, which is exactly true: readings are accumulating
    /// towards a verdict.
    ///
    /// Nothing at all was the old answer and it is the reported defect — the
    /// row came out as a bare percentage and read as breakage. A word after the
    /// figure ("settling…") was the other candidate and it is defensible, but
    /// the line already spends its tail on the estimate, and a state that ends
    /// as soon as the trend lands does not deserve the widest thing on the row.
    /// A mark in the same place as every other state's keeps the column steady
    /// while the app makes its mind up.
    ///
    /// Nil is kept for no reading at all, which is a different state: the clock
    /// has not answered, so there is no row to mark.
    static func glyph(for reading: BatteryReading?) -> String? {
        switch reading?.direction {
        case .charging: "\u{1F50C}"
        case .discharging: (reading?.percent ?? 0) < low ? "\u{1FAAB}" : "\u{1F50B}"
        case .unknown: "\u{23F3}"
        case nil: nil
        }
    }

    /// The whole line: the glyph, the percentage, and what happens next.
    ///
    /// `shownPercent` and not `percent`, and this is the only place the two are
    /// told apart. The reading flickers a percent either way on ADC noise with
    /// nothing changing, and the trajectory holds the displayed figure against
    /// that; the glyph and the colour below stay on the real one, because they
    /// are the same line the first warning fires at.
    static func text(for reading: BatteryReading?) -> String? {
        guard let reading else { return nil }
        let percent = "\(reading.shownPercent)%"
        let head = glyph(for: reading).map { "\($0) \(percent)" } ?? percent
        guard let tail = trend(for: reading) else { return head }
        return "\(head) · \(tail)"
    }

    /// What the line says after the percentage.
    ///
    /// Nothing while the direction is unknown, and nothing while charging
    /// either: the plug already says what is happening, and a word beside it is
    /// noise on a line read at a glance. A countdown is doubly out — time to
    /// empty for something filling up is a number that means nothing, and
    /// rendering one handed in by mistake would be worse than withholding it
    /// upstream.
    ///
    /// "estimating…" survives where it belongs, which is a real discharge whose
    /// rate is not established yet.
    private static func trend(for reading: BatteryReading) -> String? {
        switch reading.direction {
        case .unknown, .charging: nil
        case .discharging: reading.timeRemaining.map { "\(duration($0)) left" } ?? "estimating…"
        }
    }

    /// How urgent the line looks.
    ///
    /// Read off the direction as well as the percentage: a clock filling up at
    /// 4% is not an emergency, however low the number is.
    static func colour(for reading: BatteryReading?) -> Color {
        guard let reading, reading.direction == .discharging else { return .secondary }
        if reading.percent < critical { return .red }
        if reading.percent < low { return .orange }
        return .secondary
    }

    /// Seconds as something a person reads off a menu bar.
    ///
    /// Written out rather than handed to `DateComponentsFormatter`, which is
    /// locale-dependent: the suite would then say one thing on this machine and
    /// another on anybody else's.
    ///
    /// Quantised, and that is a claim about the estimate rather than about the
    /// formatting. It extrapolates to 0%, and lithium-ion stops being linear
    /// long before it gets there — so the number is least trustworthy exactly
    /// where somebody most wants it. "3 h 47 m" states a minute of precision
    /// nothing behind it can support, and a reader plans around what they are
    /// shown.
    /// The rungs an estimate above an hour is rounded to, in hours.
    ///
    /// Roughly a quarter apart, which is the size of the error the model behind
    /// the number actually has. A finer grid would render differences the
    /// estimate cannot tell apart.
    private static let rungs: [Double] = [1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 36, 48]

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))

        // Under the hour the five-minute grid stays, because the precision
        // there is real: the bottom of the discharge curve is steep, so the
        // voltage genuinely carries the rate and the answer is worth a figure.
        if total < 3_600 {
            let step = 5 * 60
            // Floored at one step. Under half a step rounds to nothing, and
            // "0 m" reads as a broken estimate rather than an urgent one.
            let quantised = max(((total + step / 2) / step) * step, step)
            // Except when it rounds up to the hour itself: "60 m" is the same
            // amount of time as "1 h" and a worse sentence.
            if quantised >= 3_600 { return "~1 h" }
            return "\(quantised / 60) m"
        }

        // Above it, a ladder and a tilde. The figure is a charge left over a
        // fitted rate, against a curve that is the canonical shape of a lithium
        // cell rather than a fit to this one — good to some tens of percent,
        // not to the minute. "20 h 15 m" claims four digits of a number that
        // has one, and a reader plans around the claim.
        let hours = Double(total) / 3_600
        // A 4400 mAh cell at the seventy-odd milliamps this clock cannot go
        // below is about sixty hours. Past that the model has failed rather
        // than the battery having lasted, and saying so is the honest answer.
        guard hours <= 52 else { return "2+ days" }

        let rung = rungs.min { abs($0 - hours) < abs($1 - hours) } ?? 1
        if rung >= 24 {
            let days = rung / 24
            if days == 1 { return "~1 day" }
            return days == 1.5 ? "~1.5 days" : "~\(Int(days)) days"
        }
        if rung == rung.rounded() { return "~\(Int(rung)) h" }
        return "~\(Int(rung)) h 30 m"
    }
}
