import Foundation

/// Which of the clock's three indicator lamps.
///
/// Named for where each one is rather than for its number, because the number
/// is the firmware's business and the position is the caller's. Which is which
/// was measured rather than looked up: each was lit magenta in turn and the
/// framebuffer read back through `/api/screen`, giving (0,30)(0,31)(1,31) for
/// the first, (3,31)(4,31) for the second and (6,31)(7,30)(7,31) for the third
/// — the top, middle and bottom of the two rightmost columns.
public enum IndicatorSlot: Int, Sendable, CaseIterable {
    case topRight = 1
    case middleRight = 2
    case bottomRight = 3
}

/// What a lamp is showing.
///
/// Three cases because a lamp does three things, and the third is not the
/// second in a darker colour: `off` sends the firmware's own clear rather than
/// a black colour, so the lamp stops being an indicator instead of becoming an
/// unlit one.
///
/// The blink belongs to the firmware, and that is the whole economy of this
/// channel. A blinking corner costs one POST and then nothing at all — it keeps
/// flashing through the loop's rotation, through this app being asleep, and
/// through the Mac being shut. Anything drawn in an app would have to be
/// re-sent to stay alive.
public enum IndicatorSignal: Equatable, Sendable {
    case off
    case steady(String)
    case blinking(String, everyMilliseconds: Int)

    /// The body the firmware reads.
    ///
    /// `blink` is present only when there is blinking to ask for. The firmware
    /// keys on the presence of the field, so a steady lamp that sent `blink: 0`
    /// would be describing itself in the vocabulary of the thing it is not.
    var jsonObject: [String: Any] {
        switch self {
        case .off:
            // The firmware's clear. Probed on the device: this is what put all
            // three lamps out after they were lit to find their positions.
            return ["color": "0"]
        case let .steady(colour):
            return ["color": colour]
        case let .blinking(colour, milliseconds):
            return ["color": colour, "blink": milliseconds]
        }
    }
}

extension AwtrixDevice {
    /// Lights one indicator lamp, or puts it out.
    ///
    /// Indicators are the clock's cheap channel: they draw over whatever app is
    /// showing, survive the loop rotating past, and cost no slot in it. So they
    /// carry STATE — is a thing on or off — and never a number, which has
    /// nowhere to go in eight pixels.
    public func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws {
        _ = try await postJSON("/api/indicator\(slot.rawValue)", signal.jsonObject)
    }
}

extension IndicatorSlot {
    /// What the settings and a lamp refusal call it — top, middle, bottom.
    public var lampName: String {
        switch self {
        case .topRight: "top"
        case .middleRight: "middle"
        case .bottomRight: "bottom"
        }
    }
}
