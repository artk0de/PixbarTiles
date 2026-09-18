import Foundation

/// The facts about a weekly Claude allowance that are not about drawing it.
///
/// The allowance is not a constant this app can know: a promotion widens it, a
/// plan change replaces it, and both happen without anything local changing. So
/// nothing here derives a percentage from token counts — the service reports
/// `utilization` already in percent against whatever today's allowance is, and
/// that figure is carried through untouched.
public enum ClaudeUsage {
    /// Claude's own orange. The number, the percent sign and the resting bar are
    /// all drawn in it, so at rest the app reads as one object rather than as a
    /// warning about itself.
    public static let brandColour = "#D97757"

    // Which Focus this app survives is deliberately NOT decided here.
    //
    // It was, once: a list of the two Focuses the app was for, and a check that
    // hid it everywhere else. That is the wrong shape as well as the wrong
    // answer — the exception list belongs beside the one the anecdotes already
    // use, so that a Focus added to it starts hiding this app too without
    // anybody remembering to. `ClaudeFocusAudience` owns it, in the target that
    // knows what a Focus is.
}
