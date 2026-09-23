import Foundation

/// How much of a usage window is gone, as a colour — one ramp for every
/// vendor's windows, Claude's and z.ai's alike, each below the first warning
/// in its own brand colour.
///
/// The ramp answers one question — will you run out before the window does —
/// and that is what puts its foot at three quarters rather than at half. An
/// allowance spent evenly passes half by Wednesday midday; colouring that
/// leaves the bar shouting through an ordinary week, and a warning that is on
/// half the time stops being read.
///
/// Past three quarters it steps every five points instead of leaping. Three
/// bands left a bar at eighty-one and a bar at eighty-nine the same colour, so
/// the reader had only the bar's LENGTH to tell them apart — which is the one
/// reading a 52-pixel row is worst at. Six steps make the colour say HOW close,
/// not merely "close".
///
/// A truer measure would compare the figure against how much of the week has
/// elapsed — sixty percent on Monday is alarming, ninety on Sunday evening is
/// fine. That is a second input and a second decision, and it is deliberately
/// not in this type: these thresholds are the ones that were asked for, and
/// pace can be added beside them without moving anything here.
public enum UsageBand: Sendable, Equatable, CaseIterable {
    /// Under three quarters. Nothing to say.
    case steady
    /// Three quarters gone.
    case watch
    /// Four fifths.
    case warm
    /// Seventeen twentieths.
    case hot
    /// Nine tenths.
    case close
    /// Nineteen twentieths.
    case critical
    /// The window is full, or spent past its end.
    case spent

    public init(utilization: Int) {
        switch utilization {
        case ..<75: self = .steady
        case ..<80: self = .watch
        case ..<85: self = .warm
        case ..<90: self = .hot
        case ..<95: self = .close
        case ..<100: self = .critical
        default: self = .spent
        }
    }

    /// What the filled part of a vendor's bar is drawn in: the vendor's own
    /// `brand` while the window is steady, the shared ramp past that.
    ///
    /// The ramp's colours are deliberately more saturated than either brand
    /// rather than near one — at brightness two on the panel, a warning that
    /// merely shifts hue by a little is a warning nobody notices. Shared, so
    /// yellow means three quarters gone whichever vendor's mark sits beside it.
    public func fillColour(brand: String) -> String {
        switch self {
        case .steady: brand
        case .watch: "#FFD24A"
        case .warm: "#FFAE3A"
        case .hot: "#FF8C1A"
        case .close: "#FF6321"
        case .critical: "#FF3B30"
        case .spent: "#FF0000"
        }
    }

    /// The low end of the spent pulse, and `nil` for every band that does not
    /// pulse.
    ///
    /// A full window is the one state the ramp cannot shout any louder in
    /// colour: `critical` already drives the red channel to 255, and going
    /// brighter at that hue means adding white, which walks the red toward
    /// salmon and reads as LESS urgent. So past the cap the face spends motion
    /// instead of hue and breathes between these two reds. Surfaces that
    /// cannot animate simply ignore this and draw `fillColour`.
    public var pulseColour: String? {
        self == .spent ? "#A00000" : nil
    }

    /// Claude's bar — the band in Claude's orange, as the AWTRIX face and
    /// every caller from before the band was shared read it.
    public var fillColour: String {
        fillColour(brand: ClaudeUsage.brandColour)
    }
}
