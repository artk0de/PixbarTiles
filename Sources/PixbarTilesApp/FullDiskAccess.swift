import AppKit

/// Asking for Full Disk Access, the one way macOS allows: it has no prompt for
/// this permission, so the app says why it wants it and opens the pane where
/// the user grants it — what every app that "asks" for it does.
///
/// Wanted for one read only: `DoNotDisturbDatabase`, the file that says WHICH
/// Focus is on. Without it Sleep cannot be told from any other Focus.
@MainActor
enum FullDiskAccess {
    /// Privacy & Security › Full Disk Access.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// The ask itself, raised when a tile that tells Sleep from other Focuses
    /// is added on a Mac that cannot yet name one.
    static func ask() {
        let alert = NSAlert()
        alert.messageText = "Allow Full Disk Access?"
        alert.informativeText = """
            macOS tells apps only that some Focus is on, never which one. With \
            Full Disk Access PixBar Tiles can tell Sleep from Work or Do Not \
            Disturb, and the night light can start when you go to sleep. \
            Turn PixBar Tiles on in the list that opens, then reopen the app. \
            Until then the night light follows the hours on its Common tab.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        WindowFocus.activate()
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }
}
