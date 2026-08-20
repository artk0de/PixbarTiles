import AwtrixKit
import Foundation

/// Whether the Claude app belongs on the clock under the Focus macOS is in.
///
/// Shown by default and hidden by exception, which is the opposite of how this
/// started. The first version listed the two Focuses it was FOR — work and
/// personal time — and hid it everywhere else, including under no Focus at all.
/// That reading is wrong in the ordinary case: a Mac with no Focus on is most
/// of every day, and it left the app off the clock almost always. What was
/// asked for is that the app KEEPS WORKING through work and personal time,
/// unlike the anecdotes, which those Focuses do not silence either.
///
/// So the exception list is the same one the anecdotes use — Do Not Disturb and
/// Sleep, and nothing else. Deliberately the SAME list rather than a second
/// copy of it: a Focus that silences the room is one nobody wants a lit matrix
/// under either, and two lists would drift.
enum ClaudeFocusAudience {
    static func shows(_ status: any FocusStatusReading) -> Bool {
        // An unauthorized centre cannot be believed about the mode, so its
        // answer is treated exactly like "cannot tell" rather than as "no
        // Focus" — the same defect `FocusGate.rule` exists to avoid.
        guard status.access == .authorized else { return true }

        switch status.activeMode {
        case let .mode(identifier):
            return !DoNotDisturbDatabase.silencing.contains(identifier)
        case .noFocus:
            // The ordinary state of a Mac, and the case that made the first
            // version wrong. Nothing is being silenced, so nothing is hidden.
            return true
        case .cannotTell:
            // Reading the active mode needs Full Disk Access; without it macOS
            // says only that SOME Focus is on. Shown, because hiding on "cannot
            // tell" produces an app that never appears on a machine where
            // everything else works and says nothing anywhere about why.
            return true
        }
    }
}
