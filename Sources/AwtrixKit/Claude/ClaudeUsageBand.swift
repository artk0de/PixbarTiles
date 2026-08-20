import Foundation

/// How much of the week's allowance is gone, as a colour.
///
/// The bands answer one question — will you run out before the week does — and
/// that is what puts the thresholds this late. An allowance spent evenly passes
/// half by Wednesday midday and three quarters by Friday; colouring those
/// states leaves the bar shouting through an ordinary week, and a warning that
/// is on half the time stops being read.
///
/// A truer measure would compare the figure against how much of the week has
/// elapsed — sixty percent on Monday is alarming, ninety on Sunday evening is
/// fine. That is a second input and a second decision, and it is deliberately
/// not in this type: these thresholds are the ones that were asked for, and
/// pace can be added beside them without moving anything here.
public enum ClaudeUsageBand: Sendable, Equatable, CaseIterable {
    /// Under four fifths. Nothing to say.
    case steady
    /// Four fifths gone.
    case watch
    /// Nine tenths gone.
    case close
    /// Nineteen twentieths, or past the end of the bar entirely.
    case spent

    public init(utilization: Int) {
        switch utilization {
        case ..<80: self = .steady
        case ..<90: self = .watch
        case ..<95: self = .close
        default: self = .spent
        }
    }

    /// What the filled part of the bar is drawn in.
    ///
    /// The three warning colours are deliberately more saturated than the
    /// brand's own orange rather than near it — at brightness two on an eight
    /// by thirty-two matrix, a warning that merely shifts hue by a little is a
    /// warning nobody notices.
    public var fillColour: String {
        switch self {
        case .steady: ClaudeUsage.brandColour
        case .watch: "#FFD24A"
        case .close: "#FF8C1A"
        case .spent: "#FF3B30"
        }
    }
}
