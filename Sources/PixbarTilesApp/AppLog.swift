import Foundation
import os

/// The app's one log handle, per area. The subsystem is this bundle's own
/// identifier, so `log show --predicate 'subsystem == "<bundle id>"'` finds
/// every line the app writes without anybody having to remember a string.
///
/// The app drew no log lines before the add-clock refusals needed one: an
/// answer the UI can miss (the sheet closed, the surface switched) has to be
/// diagnosable from the system log alone.
enum AppLog {
    static let clocks = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PixbarTiles",
        category: "clocks"
    )

    /// The panel's window: which one it is, whether AppKit will move it, and
    /// what a drag actually posts. None of it is visible from the app — a
    /// gesture that does nothing looks exactly like a gesture that was never
    /// made — so the drag-to-pin has to be diagnosable from the log alone.
    static let panel = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PixbarTiles",
        category: "panel"
    )
}
