import Foundation

/// A stretch of whole hours in the day, wrapping past midnight.
///
/// `QuietWindow` without its direction. Whether the hours inside are the quiet
/// ones or the working ones is the policy's to say (`TileWindow`); the window
/// only knows which hours it covers.
public struct HourWindow: Hashable, Sendable {
    /// The first hour inside, 0–23.
    public let startHour: Int
    /// The first hour outside again, 0–23 — so 23 to 8 covers 07:59 and not
    /// 08:00.
    public let endHour: Int

    /// Hours are taken round the clock, so a stored 24 is midnight rather than
    /// an hour no reading of the clock ever lands on.
    public init(startHour: Int, endHour: Int) {
        self.startHour = Self.roundTheClock(startHour)
        self.endHour = Self.roundTheClock(endHour)
    }

    /// Zero length is no window at all. The other reading — the whole day — is
    /// a tile gone permanently mute because a picker was scrolled one notch too
    /// far, with nothing on the panel to say why.
    public var isEmpty: Bool { startHour == endHour }

    public func contains(hour: Int) -> Bool {
        let hour = Self.roundTheClock(hour)
        guard !isEmpty else { return false }
        // 23 to 8 is the shipped quiet window, so the wrap is the case rather
        // than the edge case: two stretches with the day boundary between.
        guard startHour < endHour else { return hour >= startHour || hour < endHour }
        return hour >= startHour && hour < endHour
    }

    /// The window as the settings say it, `23:00–08:00`.
    public var label: String {
        "\(Self.clockFace(startHour))–\(Self.clockFace(endHour))"
    }

    /// An hour as a clock reads it. Written out rather than formatted, so the
    /// suite reads the same on every machine whatever its locale.
    public static func clockFace(_ hour: Int) -> String {
        String(format: "%02d:00", roundTheClock(hour))
    }

    private static func roundTheClock(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
