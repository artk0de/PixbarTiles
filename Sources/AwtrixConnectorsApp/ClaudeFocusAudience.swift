import AwtrixKit
import Foundation

/// Whether the Focus macOS is in right now is one of the ones the Claude app
/// belongs to.
///
/// The translation layer, and it exists so `AwtrixKit` never learns what a
/// Focus is: the kit owns the LIST of identifiers, this owns the reading of
/// what macOS currently says, and the two meet at a `Bool`.
enum ClaudeFocusAudience {
    static func shows(_ status: any FocusStatusReading) -> Bool {
        // An unauthorized centre cannot be believed about the mode, so its
        // answer is treated exactly like "cannot tell" rather than as "no
        // Focus" — the same defect `FocusGate.rule` exists to avoid.
        guard status.access == .authorized else { return true }

        switch status.activeMode {
        case let .mode(identifier):
            return ClaudeUsage.shows(focusIdentifier: identifier)
        case .noFocus:
            return false
        case .cannotTell:
            // Shown, and this is the deliberate half of the design. Reading the
            // active mode needs Full Disk Access; without it macOS says only
            // that SOME Focus is on. Hiding here would produce an app that
            // never appears on a machine where everything else works and that
            // says nothing anywhere about why — the worst failure available.
            // Showing costs a Claude app on the matrix during Do Not Disturb,
            // which is visible, harmless and self-explaining.
            return true
        }
    }
}
