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
        subsystem: Bundle.main.bundleIdentifier ?? "PixelClockTiles",
        category: "clocks"
    )
}
