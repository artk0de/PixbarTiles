import Foundation

/// The app's own folder in Application Support, and the move from the name it
/// had before.
///
/// The folder is named after the app, and the app was renamed from
/// PixelClockTiles to PixbarTiles. The old folder holds `secrets.enc` — every
/// token the user pasted — and the Claude Code hook with the document it
/// writes, so the first launch under the new name moves it across before
/// anything opens the secret store.
///
/// A move, not a copy: two folders would be two sets of secrets drifting
/// apart. And only into a gap: a new folder that already exists is newer than
/// the old one, so neither is touched and the old one stays for the user.
///
/// The anecdote store is not here: it has lived in `AwtrixConnectors` since the
/// first rename, deliberately, and still does.
public enum SupportFolder {
    /// The folder's name now.
    public static let name = "PixbarTiles"

    /// The folder's name before the rename. Kept as it was: it names where an
    /// existing installation's data is.
    public static let previousName = "PixelClockTiles"

    /// `~/Library/Application Support`.
    public static let applicationSupport: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)

    /// The folder the app reads and writes.
    public static var current: URL {
        applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    /// The folder PixelClockTiles wrote to.
    public static var previous: URL {
        applicationSupport.appendingPathComponent(previousName, isDirectory: true)
    }

    /// What `carryOver` did.
    public enum CarryOver: Equatable, Sendable {
        /// The old folder is now the new one.
        case moved
        /// There was no old folder.
        case nothingToMove
        /// Both exist; neither was touched.
        case keptBoth
    }

    /// Moves `previous` to `current` when `current` does not exist yet.
    ///
    /// One rename on one volume, so a crash leaves the folder under one name
    /// or the other and never half of it under each. Throws only when the
    /// rename itself fails, which leaves the old folder where it was.
    @discardableResult
    public static func carryOver(
        from previous: URL = previous, to current: URL = current,
        fileManager: FileManager = .default
    ) throws -> CarryOver {
        guard fileManager.fileExists(atPath: current.path) == false else { return .keptBoth }
        guard fileManager.fileExists(atPath: previous.path) else { return .nothingToMove }
        try fileManager.createDirectory(
            at: current.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: previous, to: current)
        return .moved
    }
}
