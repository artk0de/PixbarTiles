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

    /// The Focus modes this app belongs to.
    ///
    /// Identifiers rather than display names: a Focus is renamed freely in
    /// Settings and its identifier is not, so matching on the name would break
    /// the moment somebody types over "Work". Captured from the Focus database
    /// on this machine rather than guessed.
    public static let focusesItBelongsTo: Set<String> = [
        "com.apple.focus.work",
        "com.apple.focus.personal-time",
    ]

    /// Whether the weekly allowance belongs on the clock right now.
    ///
    /// Nil means no Focus is active, and that answers false: the app was asked
    /// for during working and personal hours specifically, and "no Focus at
    /// all" is neither of them.
    ///
    /// The case NOT decided here is the one where the Focus cannot be read —
    /// the app has no Full Disk Access, so the database is unreadable. That is
    /// not a Focus identifier and does not reach this function; whoever cannot
    /// tell must decide whether to show, and the reason it is their decision is
    /// that hiding on "cannot tell" produces an app which never appears and
    /// never explains why.
    public static func shows(focusIdentifier: String?) -> Bool {
        guard let focusIdentifier else { return false }
        return focusesItBelongsTo.contains(focusIdentifier)
    }
}
